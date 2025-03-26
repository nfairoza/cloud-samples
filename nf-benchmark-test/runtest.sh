#!/bin/bash

# Set variables
S3_PATH="s3://netflix-files-us-west2/cldperf-nflx-lab-benchmarks-main/"
OUTPUT_DIR="netflix-benchmark-files"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Download all files recursively using AWS CLI
echo "Downloading all files from $S3_PATH to $OUTPUT_DIR..."
aws s3 cp "$S3_PATH" "$OUTPUT_DIR" --recursive

echo "Download complete!"
