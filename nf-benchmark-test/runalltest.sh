#!/bin/bash

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <ssh-key-path>"
    echo "Example: $0 ~/.ssh/my-key.pem"
    exit 1
fi

SSH_KEY_PATH="$1"

if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "Error: SSH key file does not exist at $SSH_KEY_PATH"
    exit 1
fi

chmod 400 "$SSH_KEY_PATH"

INSTANCE_TYPES=(
    # "m7a.xlarge"
    # "m7a.2xlarge"
    # "m7a.4xlarge"
    # "m7a.8xlarge"
    # "m7a.12xlarge"
    # "m7a.16xlarge"
    # "m7a.24xlarge"
    # "m7a.32xlarge"
    # "m7a.48xlarge"
    "m7a.metal-48xl"
)

# Function to check if an instance with the given name tag already exists
check_existing_instance() {
    local instance_type=$1
    local short_type=$(echo $instance_type | sed 's/m7a\.//g')
    local name_tag="netflixtest $short_type"

    echo "Checking for existing instance with name tag: \"$name_tag\"..."

    # Get instance ID if an instance with this name tag exists and is running
    INSTANCE_ID=$(aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=\"$name_tag\"" "Name=instance-state-name,Values=running,pending" \
      --query 'Reservations[0].Instances[0].InstanceId' \
      --output text)

    # If INSTANCE_ID is not "None" and not empty, an instance exists
    if [ "$INSTANCE_ID" != "None" ] && [ ! -z "$INSTANCE_ID" ]; then
        echo "Found existing instance $INSTANCE_ID with name tag \"$name_tag\""
        return 0
    else
        echo "No existing running instance found with name tag \"$name_tag\""
        return 1
    fi
}

launch_and_benchmark() {
    local instance_type=$1
    local short_type=$(echo $instance_type | sed 's/m7a\.//g')
    local name_tag="netflixtest $short_type"
    local log_file="benchmark_${short_type}.log"

    check_existing_instance $instance_type
    if [ $? -eq 0 ]; then
        echo "Using existing instance $INSTANCE_ID ($instance_type)..."
    else
        echo "Launching new $instance_type instance..."

        INSTANCE_ID=$(aws ec2 run-instances \
          # --image-id ami-04f167a56786e4b09 \ 24 version ubuntu
          --image-id ami-0c3b809fcf2445b6a \ #22.04 version ubuntu
          --instance-type $instance_type \
          --key-name noor-ohio \
          --security-group-ids sg-0af511081e75fe69e \
          --subnet-id subnet-9f9892e5 \
          --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":50,\"DeleteOnTermination\":true}}]" \
          --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=\"$name_tag\"}]" \
          --iam-instance-profile Name=testadmin \
          --query 'Instances[0].InstanceId' \
          --output text)

        echo "Instance $INSTANCE_ID ($instance_type) is launching..."

        aws ec2 wait instance-running --instance-ids $INSTANCE_ID
        echo "Instance $INSTANCE_ID ($instance_type) is running. Waiting for status checks..."

        aws ec2 wait instance-status-ok --instance-ids $INSTANCE_ID
        echo "Instance $INSTANCE_ID ($instance_type) is ready."
    fi

    PUBLIC_IP=$(aws ec2 describe-instances \
      --instance-ids $INSTANCE_ID \
      --query 'Reservations[0].Instances[0].PublicIpAddress' \
      --output text)

    echo "Instance $INSTANCE_ID ($instance_type) public IP: $PUBLIC_IP"
    echo "Connecting to instance $INSTANCE_ID ($instance_type) and running benchmarks..."

    # Create a temporary script file with the commands to run
    TMP_SCRIPT=$(mktemp)
    cat << EOF > $TMP_SCRIPT
echo "Connected to \$(hostname) - Running $instance_type benchmarks"

# Check if benchmarks are already running
if pgrep -f "start-benchmarks.sh" > /dev/null; then
    echo "Benchmarks are already running on this instance. Exiting."
    exit 0
fi

# Always download the latest startup script
echo "Downloading latest startup script..."
sudo wget -O startup.sh https://raw.githubusercontent.com/nfairoza/benchmarks-data/refs/heads/main/cldperf-nflx-lab-benchmarks-main/autobench-aws/startup.sh
sudo chmod +x startup.sh

# Always run the startup script to ensure latest environment
echo "Running startup script..."
sudo ./startup.sh
fi
sudo ./benchmarks_environment.sh
# Change to the autobench directory
cd /home/ubuntu/cldperf-nflx-lab-benchmarks-main/autobench

# Run benchmarks with no profiling in non-interactive mode
echo "Running benchmarks with no profiling..."
sudo ./start-benchmarks.sh no all &


# Run benchmarks with perfspec profiling in non-interactive mode
echo "Running benchmarks with perfspec profiling..."
sudo ./start-benchmarks.sh perfspec all

# Run benchmarks with uProf profiling in non-interactive mode
echo "Running benchmarks with uProf profiling..."
sudo ./start-benchmarks.sh uProf all

# Upload the results
echo "Uploading results to S3..."
sudo ./upload-results.sh

echo "Benchmark process completed for $instance_type."
EOF

    # Use SSH with -n flag for non-interactive mode
    ssh -n -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$PUBLIC_IP "bash -s" < $TMP_SCRIPT >> $log_file 2>&1 &

    # Store the PID of the SSH process
    SSH_PID=$!
    echo "Started benchmarks on $instance_type (SSH PID: $SSH_PID). Check $log_file for progress."

    # Clean up temp script
    rm $TMP_SCRIPT
}

echo "Starting benchmark launches..."

for instance_type in "${INSTANCE_TYPES[@]}"; do
    launch_and_benchmark "$instance_type" &
    sleep 5  # Small delay to avoid API rate limiting
done

echo "All benchmark processes have been initiated in the background."
echo "You can check the individual log files for each instance type:"
echo "  benchmark_xlarge.log, benchmark_2xlarge.log, etc."
echo "The script will continue running benchmarks even if you close this terminal."
