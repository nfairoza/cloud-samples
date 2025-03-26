#!/bin/bash

# Set variables
S3_PATH="s3://netflix-files-us-west2/cldperf-nflx-lab-benchmarks-main/"
TARGET_DIR="cldperf-nflx-lab-benchmarks-main"
GIT_REPO="https://github.com/nfairoza/cloud-samples.git"
GIT_SUBDIR="nf-benchmark-test"
TEMP_DIR="temp_git_clone"

# Check if the target directory exists
if [ ! -d "$TARGET_DIR" ]; then
    echo "Target directory $TARGET_DIR does not exist. Downloading from S3..."
    aws s3 cp "$S3_PATH" "$TARGET_DIR" --recursive

    if [ $? -ne 0 ]; then
        echo "S3 download failed."
        exit 1
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
    exit 1
fi

# Copy all files from GitHub to autobench
echo "Copying all files to $TARGET_DIR/autobench..."
cp "$TEMP_DIR/$GIT_SUBDIR"/* "$TARGET_DIR/autobench/" 2>/dev/null || echo "Warning: No files found or couldn't be copied"

# Make all files executable
echo "Making all files executable..."
chmod +x "$TARGET_DIR/autobench"/*

# Clean up the temporary directory
rm -rf "$TEMP_DIR"

echo "All operations completed! Files have been copied to $TARGET_DIR/autobench and made executable."
