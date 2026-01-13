#!/bin/bash
set -e
S3_BUCKET="noortestdata"
S3_PREFIX="perfspect/intel-runs"

TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_TYPE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
CPU_COUNT=$(nproc)

echo "Updating system and installing dependencies..."
sudo apt-get update -y
sudo apt-get install -y unzip wget tar stress-ng


if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    sudo ./aws/install --update
    rm -rf aws awscliv2.zip
fi


cd $HOME
rm -rf perfspect/


mkdir -p $HOME/perfspect_run
cd $HOME/perfspect_run

echo "Downloading Intel PerfSpect..."
wget -qO- https://github.com/intel/PerfSpect/releases/latest/download/perfspect.tgz | tar -xvz

chmod +x perfspect

cd perfspect

collect_perfspect() {
    local load_level=$1
    if [ -d "perfspect" ]; then
      sudo rm -rf perfspect
    fi


    OLD_DIRS=$(ls -d perfspect_* 2>/dev/null)


    echo ".................Starting report for ${load_level}................."
    sudo ./perfspect report 

    echo ".................Running metrics for ${load_level}................."
    sudo ./perfspect metrics --duration 30

    echo ".................Generating flame graph for ${load_level}................."
    sudo ./perfspect flame --duration 30

    echo ".................Collecting telemetry for ${load_level}................."
    sudo ./perfspect telemetry --duration 30

    echo ".................Running lock for ${load_level}................."
    sudo ./perfspect lock --duration 30

    NEW_DIRS=$(comm -13 <(echo "$OLD_DIRS" | sort) <(ls -d perfspect_* 2>/dev/null | sort))

    if [ -n "$NEW_DIRS" ]; then
        TAR_NAME="perfspect_int_${INSTANCE_TYPE}_${load_level}.tar.gz"
        echo "Archiving: $NEW_DIRS"
        sudo tar -czf "$TAR_NAME" $NEW_DIRS

        echo "Uploading to S3: s3://${S3_BUCKET}/${S3_PREFIX}/$TAR_NAME"
        aws s3 cp "$TAR_NAME" "s3://${S3_BUCKET}/${S3_PREFIX}/$TAR_NAME"

        # Cleanup to save disk space
        sudo rm "$TAR_NAME"
        sudo rm -rf $NEW_DIRS
    else
        echo "Error: No data was collected for ${load_level}. Check perfspect logs."
    fi
}

collect_perfspect "idle"

stress-ng --cpu $CPU_COUNT --cpu-load 50 --cpu-method matrixprod &
STRESS_PID=$!
sleep 30
collect_perfspect "50load"
kill $STRESS_PID
sleep 30

stress-ng --cpu $CPU_COUNT --cpu-load 100 --cpu-method matrixprod &
STRESS_PID=$!
sleep 30
collect_perfspect "fullload"
kill $STRESS_PID
