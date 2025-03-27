#!/bin/bash
#
# Benchmark Environment Setup Script
# This script sets up the environment for running benchmarks and downloads necessary files
#

echo "Starting benchmark environment setup..."

# Define variables and paths
HOME_DIR="/home/ubuntu"
CLDPERF_DIR="$HOME_DIR/cldperf-nflx-lab-benchmarks-main"
AUTOBENCH_DIR="$CLDPERF_DIR/autobench"
#/home/ubuntu/cldperf-nflx-lab-benchmarks-main/autobench
S3_PATH="s3://netflix-files-us-west2/cldperf-nflx-lab-benchmarks-main/"
GIT_REPO="https://github.com/nfairoza/cloud-samples.git"
GIT_SUBDIR="nf-benchmark-test"
TEMP_DIR="$HOME_DIR/temp_git_clone"

# Update packages
echo "Updating package lists and installing required packages..."
sudo apt update
sudo add-apt-repository -y ppa:graphics-drivers/ppa
sudo apt update
sudo ubuntu-drivers autoinstall
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
    git \
    nvidia-headless-570


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
sudo chown -R bnetflix:bnetflix "$LOCAL_RESULTS_DIR"
sudo chmod -R 755 "$LOCAL_RESULTS_DIR"
sudo -u bnetflix  mv $AUTOBENCH_DIR/run-benchmarks $AUTOBENCH_DIR/run-benchmarks.sh

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

    if [ -d "$AUTOBENCH_DIR" ]; then
        echo "Found autobench directory at $AUTOBENCH_DIR"
        echo "Copying files from GitHub to $AUTOBENCH_DIR..."
        sudo cp -f "$TEMP_DIR/$GIT_SUBDIR"/* "$AUTOBENCH_DIR/" 2>/dev/null || echo "Warning: No files found or couldn't be copied"

        # Make all files executable
        echo "Making all files executable..."
        sudo chmod -R +x "$AUTOBENCH_DIR"
    else
        echo "Warning: autobench directory not found at $AUTOBENCH_DIR"
        echo "Creating autobench directory and copying files from GitHub..."
        sudo mkdir -p "$AUTOBENCH_DIR"
        sudo cp -f "$TEMP_DIR/$GIT_SUBDIR"/* "$AUTOBENCH_DIR/" 2>/dev/null
        sudo chmod -R +x "$AUTOBENCH_DIR"
    fi
    sudo rm -rf "$TEMP_DIR"
    echo "GitHub repository processing complete."
fi


sudo chmod +x "$AUTOBENCH_DIR/run-benchmarks.sh" 2>/dev/null || true
sudo chmod +x "$AUTOBENCH_DIR/benchmarks_environment.sh" 2>/dev/null || true
sudo chmod +x "$AUTOBENCH_DIR/launch_containers-concurrent.sh" 2>/dev/null || true
sudo chmod -R +x "$AUTOBENCH_DIR/benchmarks" 2>/dev/null || true
sudo chmod -R +x "$AUTOBENCH_DIR/binaries" 2>/dev/null || true

echo "Changing ownership to bnetflix..."
sudo chown -R bnetflix:bnetflix "$CLDPERF_DIR"

echo "Setup complete! You can now run benchmarks."
echo "To run benchmarks, execute: sudo -u bnetflix $AUTOBENCH_DIR/run-benchmarks.sh"
