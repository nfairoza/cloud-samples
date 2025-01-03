#!/usr/bin/env bash


# Install required packages
sudo apt-get update
sudo apt-get install -y stress-ng linux-tools-common linux-tools-generic

# Get instance ID
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

# Test CloudWatch permission
aws cloudwatch put-metric-data \
  --namespace "CPUStressTest" \
  --metric-name "TestMetric" \
  --value "100" \
  --dimensions "InstanceId=$INSTANCE_ID"

# Test turbostat
sudo turbostat --show Busy%,Bzy_MHz --quiet > test.csv

# Check if turbostat output is correct
cat test.csv
