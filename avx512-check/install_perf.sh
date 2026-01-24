#!/bin/bash

#############################################################################
# install_perf.sh
#
# Automated script to build and install perf from kernel source on Ubuntu
# Useful for AWS/cloud instances where linux-tools packages are unavailable
#
# # Create the script
# nano install_perf.sh
# # Paste the content from the artifact above
#
# # Make it executable
# chmod +x install_perf.sh
#
# # Run it (without sudo)
# ./install_perf.sh
#
# # After installation
# source ~/.bashrc
# perf --version
#############################################################################

set -e

# Get kernel version
KERNEL_VERSION=$(uname -r | cut -d'-' -f1)
KERNEL_MAJOR=$(echo $KERNEL_VERSION | cut -d'.' -f1)
BUILD_DIR="/tmp/linux-${KERNEL_VERSION}"

echo "======================================"
echo "Perf Installation Script"
echo "======================================"
echo "Detected kernel: $(uname -r)"
echo "Kernel version: ${KERNEL_VERSION}"
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo "ERROR: Please do not run this script as root. It will ask for sudo when needed."
    exit 1
fi

# Step 1: Install dependencies
echo "[STEP 1/9] Installing build dependencies..."
sudo apt-get update
sudo apt-get install -y \
    wget \
    flex \
    bison \
    libelf-dev \
    libunwind-dev \
    libaudit-dev \
    libslang2-dev \
    libperl-dev \
    python3-dev \
    binutils-dev \
    liblzma-dev \
    libzstd-dev \
    libcap-dev \
    libnuma-dev \
    libbabeltrace-dev \
    systemtap-sdt-dev \
    libssl-dev \
    libdw-dev \
    pkg-config \
    libtraceevent-dev \
    libtracefs-dev \
    build-essential

echo "Dependencies installed successfully"
echo ""

# Step 2: Download kernel source
echo "[STEP 2/9] Downloading kernel source (${KERNEL_VERSION})..."

# Remove old build directory if it exists
if [ -d "$BUILD_DIR" ]; then
    echo "Removing existing build directory: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

cd /tmp

# Download kernel source
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/linux-${KERNEL_VERSION}.tar.xz"
echo "Downloading from: $KERNEL_URL"

wget "$KERNEL_URL"

echo "Download complete"
echo ""

# Step 3: Extract source
echo "[STEP 3/9] Extracting kernel source..."
tar xf "linux-${KERNEL_VERSION}.tar.xz"

if [ ! -d "$BUILD_DIR" ]; then
    echo "ERROR: Build directory not found: $BUILD_DIR"
    exit 1
fi

echo "Source extracted successfully"
echo ""

# Step 4: Build perf
echo "[STEP 4/9] Building perf (this may take several minutes)..."
cd "${BUILD_DIR}/tools/perf"

# Clean any previous build
make clean 2>/dev/null || true

# Build with parallel jobs
NPROC=$(nproc)
echo "Using $NPROC parallel jobs..."

make -j${NPROC}

# Verify perf binary exists
if [ ! -f "perf" ]; then
    echo "ERROR: Perf binary not found after build"
    exit 1
fi

echo "Build successful"
echo ""

# Step 5: Verify build
echo "[STEP 5/9] Verifying build..."
ls -lh perf
echo ""

# Step 6: Install perf
echo "[STEP 6/9] Installing perf to /usr/local/bin..."
sudo cp perf /usr/local/bin/

if [ ! -f "/usr/local/bin/perf" ]; then
    echo "ERROR: Failed to copy perf to /usr/local/bin"
    exit 1
fi

ls -lh /usr/local/bin/perf
echo "Perf installed successfully"
echo ""

# Step 7: Configure permissions for perf
echo "[STEP 7/9] Configuring perf permissions..."
echo "Setting kernel parameters to allow perf usage without sudo..."

echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid
echo 0 | sudo tee /proc/sys/kernel/kptr_restrict

# Make changes persistent
if ! grep -q "kernel.perf_event_paranoid" /etc/sysctl.conf; then
    echo "kernel.perf_event_paranoid = -1" | sudo tee -a /etc/sysctl.conf
fi

if ! grep -q "kernel.kptr_restrict" /etc/sysctl.conf; then
    echo "kernel.kptr_restrict = 0" | sudo tee -a /etc/sysctl.conf
fi

echo "Permissions configured successfully"
echo ""

# Step 8: Add alias to bashrc
echo "[STEP 8/9] Adding perf alias to ~/.bashrc..."

if ! grep -q 'alias perf="/usr/local/bin/perf"' ~/.bashrc; then
    echo 'alias perf="/usr/local/bin/perf"' >> ~/.bashrc
    echo "Alias added to ~/.bashrc"
else
    echo "Alias already exists in ~/.bashrc"
fi
echo ""

# Step 9: Cleanup
echo "[STEP 9/9] Cleaning up temporary files..."
cd ~
rm -rf "${BUILD_DIR}"
rm -f "/tmp/linux-${KERNEL_VERSION}.tar.xz"
echo "Cleanup complete"
echo ""

# Verify installation
echo "======================================"
echo "Verifying installation..."
echo "======================================"

/usr/local/bin/perf --version

echo ""
echo "======================================"
echo "Installation Complete!"
echo "======================================"
echo ""
echo "To use perf immediately in this session:"
echo "  source ~/.bashrc"
echo "  perf --version"
echo ""
echo "Or use the full path:"
echo "  /usr/local/bin/perf --version"
echo ""
echo "Test perf with:"
echo "  perf list | head -20"
echo "  perf stat ls"
echo ""
echo "For DGEMM monitoring:"
echo "  perf stat -e cycles,instructions ./dgemm_avx512 4096 60"
echo ""
