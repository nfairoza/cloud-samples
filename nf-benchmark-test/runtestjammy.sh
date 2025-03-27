#!/bin/bash
#
# Benchmark Environment Setup Script
# This script sets up the environment for running benchmarks and downloads necessary files
#

echo "Starting benchmark environment setup..."

# Define variables and paths
HOME_DIR="/home/ubuntu"
WORKDIR="$HOME_DIR/benchmarks"
S3_PATH="s3://netflix-files-us-west2/cldperf-nflx-lab-benchmarks-main/"
CLDPERF_DIR="$HOME_DIR/cldperf-nflx-lab-benchmarks-main"
GIT_REPO="https://github.com/nfairoza/cloud-samples.git"
GIT_SUBDIR="nf-benchmark-test"
TEMP_DIR="$HOME_DIR/temp_git_clone"

# Update packages
echo "Updating package lists and installing required packages..."
sudo apt update
sudo apt install -y \
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
    git


install_aws_cli() {
        echo "Installing AWS CLI..."

        . /etc/os-release
        arch=$(uname -m)

        case "$ID" in
            ubuntu|debian)
                sudo apt update && sudo apt upgrade -y
                sudo apt install -y unzip
                ;;
            centos|rhel|almalinux|rocky|amazon)
                sudo yum update -y
                sudo yum install -y unzip
                ;;
            sles|opensuse-leap)
                sudo zypper refresh && sudo zypper update -y
                sudo zypper install -y unzip
                ;;
            *)
                echo "Unsupported Linux distribution: $ID."
                exit 1
                ;;
        esac

        if [[ "$arch" == "x86_64" ]]; then
            curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        elif [[ "$arch" == "aarch64" ]]; then
            curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
        else
            echo "Unsupported architecture: $arch"
            exit 1
        fi

        unzip awscliv2.zip
        sudo ./aws/install
        rm -rf awscliv2.zip aws
    }
# Check if AWS CLI is installed, install if not
if ! aws --version &>/dev/null; then
        echo "AWS CLI not found. Installing..."
        install_aws_cli
fi

echo "Cleaning up package cache..."
sudo apt clean

echo "Creating necessary directories..."
sudo mkdir -p /mnt
sudo chmod 777 /mnt

# Create and setup directories with proper permissions
sudo mkdir -p $WORKDIR
sudo chmod -R 777 $WORKDIR

# Check if cldperf directory exists, download from S3 if needed
echo "Checking for benchmark files..."
if [ ! -d "$CLDPERF_DIR" ]; then
    echo "Directory $CLDPERF_DIR does not exist. Attempting to download from S3..."

    # Now that we've ensured AWS CLI is available, try the S3 download
    aws s3 cp "$S3_PATH" "$CLDPERF_DIR" --recursive

    if [ $? -ne 0 ]; then
        echo "S3 download failed or aws CLI not configured properly."
    else
        echo "S3 download complete!"
    fi
else
    echo "Directory $CLDPERF_DIR already exists. Using existing files."
fi

echo "Creating user 'bnetflix' with sudo privileges..."
if ! id -u bnetflix &>/dev/null; then
    sudo useradd -m -s /bin/bash bnetflix
fi

# Ensure the sudoers entry is correctly set
echo "Setting up passwordless sudo for bnetflix..."
echo "bnetflix ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/bnetflix >/dev/null
sudo chmod 440 /etc/sudoers.d/bnetflix

# Verify sudo works without password
echo "Verifying passwordless sudo setup..."
sudo -u bnetflix sudo -n true
if [ $? -ne 0 ]; then
    echo "WARNING: Passwordless sudo for bnetflix is not working properly."
    echo "You may be prompted for a password when running benchmarks."
else
    echo "Passwordless sudo for bnetflix is configured correctly."
fi

echo "Setting up Java environment variables..."
sudo bash -c "cat << EOF >> /home/bnetflix/.bashrc
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH="\$JAVA_HOME/bin:\$PATH"
EOF"

echo "Setting up the working directory..."
cd $HOME_DIR

echo "Downloading files from GitHub repository..."
if [ -d "$TEMP_DIR" ]; then
    sudo rm -rf "$TEMP_DIR"
fi

git clone --depth 1 "$GIT_REPO" "$TEMP_DIR"

if [ $? -ne 0 ]; then
    echo "Failed to clone the GitHub repository."
    exit 1
else
    # Files should be in cldperf-nflx-lab-benchmarks-main/autobench directory
    AUTOBENCH_DIR="$CLDPERF_DIR/autobench"
    # Copy files from GitHub to augment what we have, but don't create autobench if it doesn't exist
    if [ -d "$AUTOBENCH_DIR" ]; then
        echo "Found autobench directory at $AUTOBENCH_DIR"
        echo "Copying files from GitHub to $AUTOBENCH_DIR..."
        sudo cp -f "$TEMP_DIR/$GIT_SUBDIR"/* "$AUTOBENCH_DIR/" 2>/dev/null || echo "Warning: No files found or couldn't be copied"

        # Make all files executable
        echo "Making all files executable..."
        sudo chmod -R +x "$AUTOBENCH_DIR"
    else
        echo "Warning: autobench directory not found at $AUTOBENCH_DIR"
        echo "Files won't be copied from GitHub to autobench"
    fi

    # Clean up the temporary directory
    sudo rm -rf "$TEMP_DIR"

    echo "GitHub repository processing complete."
fi

echo "Setting up main benchmark scripts..."

# Create benchmark directories
sudo mkdir -p $WORKDIR/benchmarks
sudo mkdir -p $WORKDIR/binaries

# Copy benchmark environment script
if [ -f "$AUTOBENCH_DIR/benchmarks_environment.sh" ]; then
    sudo cp "$AUTOBENCH_DIR/benchmarks_environment.sh" $WORKDIR/
else
    echo "Warning: Could not find benchmarks_environment.sh in downloaded files"
fi

# Copy run-benchmarks script
if [ -f "$AUTOBENCH_DIR/run-benchmarks.sh" ]; then
    sudo cp "$AUTOBENCH_DIR/run-benchmarks.sh" $WORKDIR/
else
    echo "Warning: Could not find run-benchmarks.sh in downloaded files"
fi

# Copy launch containers script
if [ -f "$AUTOBENCH_DIR/launch_containers-concurrent.sh" ]; then
    sudo cp "$AUTOBENCH_DIR/launch_containers-concurrent.sh" $WORKDIR/
else
    echo "Warning: Could not find launch_containers-concurrent.sh in downloaded files"
fi

# Copy benchmark files if directory exists
if [ -d "$AUTOBENCH_DIR/benchmarks" ]; then
    sudo cp -r "$AUTOBENCH_DIR/benchmarks"/* $WORKDIR/benchmarks/ 2>/dev/null || echo "Warning: Could not copy benchmark files"
else
    echo "Warning: Could not find benchmarks directory in downloaded files"
fi

# Copy binary files if directory exists
if [ -d "$AUTOBENCH_DIR/binaries" ]; then
    sudo cp -r "$AUTOBENCH_DIR/binaries"/* $WORKDIR/binaries/ 2>/dev/null || echo "Warning: Could not copy binary files"
else
    echo "Warning: Could not find binaries directory in downloaded files"
fi

# Create encode_home and vmf_home directories if they exist in source
if [ -d "$AUTOBENCH_DIR/encode_home" ]; then
    sudo mkdir -p $WORKDIR/encode_home
    sudo cp -r "$AUTOBENCH_DIR/encode_home"/* $WORKDIR/encode_home/ 2>/dev/null
fi

if [ -d "$AUTOBENCH_DIR/vmf_home" ]; then
    sudo mkdir -p $WORKDIR/vmf_home
    sudo cp -r "$AUTOBENCH_DIR/vmf_home"/* $WORKDIR/vmf_home/ 2>/dev/null
fi

echo "Setting correct permissions..."
sudo chmod +x $WORKDIR/run-benchmarks.sh 2>/dev/null || true
sudo chmod +x $WORKDIR/benchmarks_environment.sh 2>/dev/null || true
sudo chmod +x $WORKDIR/launch_containers-concurrent.sh 2>/dev/null || true
sudo chmod -R +x $WORKDIR/benchmarks 2>/dev/null || true
sudo chmod -R +x $WORKDIR/binaries 2>/dev/null || true

echo "Changing ownership to bnetflix..."
sudo chown -R bnetflix:bnetflix $WORKDIR

echo "Setup complete! You can now run benchmarks."
echo "To run benchmarks, execute: sudo -u bnetflix $WORKDIR/run-benchmarks.sh"

# Optional: Run benchmarks immediately
read -p "Do you want to run benchmarks now? (y/n): " choice
if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
    echo "Running benchmarks..."
    cd $WORKDIR
    sudo -u bnetflix $WORKDIR/run-benchmarks.sh

    # Optionally launch container benchmarks if available
    read -p "Would you like to run container-based benchmarks? (y/n): " container_choice
    if [[ "$container_choice" == "y" || "$container_choice" == "Y" ]]; then
        if [ -f "$WORKDIR/launch_containers-concurrent.sh" ]; then
            echo "Launching container benchmarks..."
            sudo -u bnetflix $WORKDIR/launch_containers-concurrent.sh 2xlarge 4xlarge
        else
            echo "Container launch script not found."
        fi
    fi
fi
