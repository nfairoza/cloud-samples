#!/bin/bash

echo "Starting benchmark environment setup..."

# Check if running as root or with sudo
if [ "$(id -u)" -ne 0 ]; then
    echo "Some operations in this script require root privileges."
    echo "We'll use sudo for those specific operations only."
    SUDO="sudo"
else
    SUDO=""
fi

echo "Setting non-interactive mode for package installation..."
export DEBIAN_FRONTEND=noninteractive

echo "Updating package lists and installing required packages..."
$SUDO apt update
$SUDO apt install -y \
    sudo \
    openjdk-17-jre-headless \
    openjdk-17-jdk-headless \
    linux-headers-$(uname -r) \
    p7zip-full \
    sysbench \
    lmbench \
    docker.io \
    docker-compose \
    cgroup-tools \
    python3-pip \
    python3 \
    g++ \
    git \
    awscli

echo "Cleaning up package cache..."
$SUDO apt clean

echo "Creating necessary directories..."
$SUDO mkdir -p /mnt
$SUDO chmod 777 /mnt

echo "Creating user 'bnetflix' with sudo privileges..."
id -u bnetflix &>/dev/null || $SUDO useradd -m -s /bin/bash bnetflix
echo "bnetflix ALL=(ALL) NOPASSWD: ALL" | $SUDO tee /etc/sudoers.d/bnetflix >/dev/null

echo "Setting up Java environment variables..."
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH="$JAVA_HOME/bin:$PATH"

# Add environment variables to bnetflix's .bashrc
if [ "$USER" = "bnetflix" ]; then
    cat << EOF >> $HOME/.bashrc
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH="\$JAVA_HOME/bin:\$PATH"
EOF
else
    $SUDO bash -c "cat << EOF >> /home/bnetflix/.bashrc
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH="\\\$JAVA_HOME/bin:\\\$PATH"
EOF"
fi

echo "Setting up the working directory..."
WORKDIR="$HOME/benchmarks"
mkdir -p $WORKDIR
cd $WORKDIR
##################################runtest.sh############################################
# Set variables for downloading benchmark files
S3_PATH="s3://netflix-files-us-west2/cldperf-nflx-lab-benchmarks-main/"
TARGET_DIR="$HOME/cldperf-nflx-lab-benchmarks-main"
AUTOBENCH_DIR="$TARGET_DIR/cldperf-nflx-lab-benchmarks-main/autobench"
GIT_REPO="https://github.com/nfairoza/cloud-samples.git"
GIT_SUBDIR="nf-benchmark-test"
TEMP_DIR="$HOME/temp_git_clone"

echo "Downloading benchmark files from S3 and GitHub..."

# Check if the target directory exists and download from S3 if needed
if [ ! -d "$TARGET_DIR" ]; then
    echo "Target directory $TARGET_DIR does not exist. Downloading from S3..."
    sudo -u bnetflix aws s3 cp "$S3_PATH" "$TARGET_DIR" --recursive

    if [ $? -ne 0 ]; then
        echo "S3 download failed. Creating empty directory for GitHub files."
        mkdir -p "$TARGET_DIR/autobench"
    else
        echo "S3 download complete!"
    fi
else
    echo "Target directory $TARGET_DIR already exists. Proceeding with updates..."
fi

# Download files from GitHub
echo "Downloading files from GitHub repository..."
mkdir -p "$TEMP_DIR"

# Clone the repository
git clone --depth 1 "$GIT_REPO" "$TEMP_DIR"

if [ $? -ne 0 ]; then
    echo "Failed to clone the GitHub repository."
    rm -rf "$TEMP_DIR"
else
    # Create autobench directory if it doesn't exist
    mkdir -p "$AUTOBENCH_DIR"

    # Copy all files from GitHub to autobench
    echo "Copying all files to $AUTOBENCH_DIR..."
    cp "$TEMP_DIR/$GIT_SUBDIR"/* "$AUTOBENCH_DIR/" 2>/dev/null || echo "Warning: No files found or couldn't be copied"

    # Make all files executable
    echo "Making all files executable..."
    chmod +x "$AUTOBENCH_DIR"/*

    # Clean up the temporary directory
    rm -rf "$TEMP_DIR"

    echo "GitHub files have been downloaded and copied to $AUTOBENCH_DIR."
fi

echo "Setting up main benchmark scripts..."

# Copy necessary files from the downloaded repositories
mkdir -p $WORKDIR/benchmarks
mkdir -p $WORKDIR/binaries

# Copy benchmark environment script
if [ -f "$AUTOBENCH_DIR/benchmarks_environment.sh" ]; then
    cp "$AUTOBENCH_DIR/benchmarks_environment.sh" $WORKDIR/
else
    echo "Warning: Could not find benchmarks_environment.sh in downloaded files"
fi

# Copy run-benchmarks script
if [ -f "$AUTOBENCH_DIR/run-benchmarks.sh" ]; then
    cp "$AUTOBENCH_DIR/run-benchmarks.sh" $WORKDIR/run-benchmarks.sh
else
    echo "Warning: Could not find run-benchmarks.sh in downloaded files"
fi

# Copy benchmark files
if [ -d "$AUTOBENCH_DIR/benchmarks" ]; then
    cp -r "$AUTOBENCH_DIR/benchmarks"/* $WORKDIR/benchmarks/ 2>/dev/null || echo "Warning: No benchmark files found"
else
    echo "Warning: Could not find benchmarks directory in downloaded files"
fi

# Copy binary files
if [ -d "$AUTOBENCH_DIR/binaries" ]; then
    cp -r "$AUTOBENCH_DIR/binaries"/* $WORKDIR/binaries/ 2>/dev/null || echo "Warning: No binary files found"
else
    echo "Warning: Could not find binaries directory in downloaded files"
fi

# Create encode_home and vmf_home directories if they exist in source
if [ -d "$AUTOBENCH_DIR/encode_home" ]; then
    mkdir -p $WORKDIR/encode_home
    cp -r "$AUTOBENCH_DIR/encode_home"/* $WORKDIR/encode_home/ 2>/dev/null
fi

if [ -d "$AUTOBENCH_DIR/vmf_home" ]; then
    mkdir -p $WORKDIR/vmf_home
    cp -r "$AUTOBENCH_DIR/vmf_home"/* $WORKDIR/vmf_home/ 2>/dev/null
fi

echo "Setting correct permissions..."
chmod +x $WORKDIR/run-benchmarks.sh
chmod +x $WORKDIR/benchmarks_environment.sh
chmod -R +x $WORKDIR/benchmarks
chmod -R +x $WORKDIR/binaries
# Create symbolic links to files in systemctl-service if needed
if [ -d "$TARGET_DIR/cldperf-nflx-lab-benchmarks-main/systemctl-service" ]; then
    SYSTEMCTL_DIR="$TARGET_DIR/cldperf-nflx-lab-benchmarks-main/systemctl-service"

    # Install packages if packages-installed.sh exists
    if [ -f "$SYSTEMCTL_DIR/packages-installed.sh" ]; then
        echo "Found packages-installed.sh, executing..."
        chmod +x "$SYSTEMCTL_DIR/packages-installed.sh"
        "$SYSTEMCTL_DIR/packages-installed.sh"
    fi

    # Copy sudo-no-passwd if it exists
    if [ -f "$SYSTEMCTL_DIR/sudo-no-passwd" ]; then
        echo "Configuring sudo-no-passwd settings..."
        $SUDO cp "$SYSTEMCTL_DIR/sudo-no-passwd" /etc/sudoers.d/
        $SUDO chmod 440 /etc/sudoers.d/sudo-no-passwd
    fi
fi

echo "Changing ownership to bnetflix if needed..."
if [ "$USER" != "bnetflix" ]; then
    $SUDO chown -R bnetflix:bnetflix $WORKDIR
fi

echo "Setup complete! You can now run benchmarks as the bnetflix user."
echo "To run benchmarks, execute: sudo -u bnetflix $WORKDIR/run-benchmarks"

# Optional: Run benchmarks immediately
read -p "Do you want to run benchmarks now? (y/n): " choice
if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
    echo "Running benchmarks as bnetflix user..."
    cd $WORKDIR
    su - bnetflix -c "$WORKDIR/run-benchmarks.sh"

    # Optionally launch container benchmarks if available
    read -p "Would you like to run container-based benchmarks? (y/n): " container_choice
    if [[ "$container_choice" == "y" || "$container_choice" == "Y" ]]; then
        if [ -f "$AUTOBENCH_DIR/launch_containers-concurrent.sh" ]; then
            echo "Launching container benchmarks..."
            cp "$AUTOBENCH_DIR/launch_containers-concurrent.sh" $WORKDIR/
            chmod +x $WORKDIR/launch_containers-concurrent.sh
            su - bnetflix -c "$WORKDIR/launch_containers-concurrent.sh 2xlarge 4xlarge"
        else
            echo "Container launch script not found."
        fi
    fi
fi
