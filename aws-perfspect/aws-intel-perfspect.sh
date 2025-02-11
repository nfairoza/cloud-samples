#!/bin/bash
S3_BUCKET="noortestdata"
S3_PREFIX="perfspect/intel-runs"

TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_TYPE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
CPU_COUNT=$(nproc)

collect_perfspect() {
    local load_level=$1
    if [ -d "perfspect" ]; then
      sudo rm -rf perfspect
    fi

    wget -qO- https://github.com/intel/PerfSpect/releases/latest/download/perfspect.tgz | sudo tar xvz
    cd perfspect
    chmod +x perfspect
    ls

    OLD_DIRS=$(ls -d perfspect_* 2>/dev/null)
    echo ".................Starting report for ${load_level}................."
    sudo ./perfspect report
    echo ".................Running metrics for ${load_level}................."
    sudo ./perfspect metrics --duration 60
    echo ".................Generating flame graph for ${load_level}................."
    sudo ./perfspect flame
    echo ".................Collecting telemetry for ${load_level}................."
    sudo ./perfspect telemetry --duration 60
    echo ".................Running lock for ${load_level}................."
    sudo ./perfspect lock

    NEW_DIRS=$(comm -13 <(echo "$OLD_DIRS" | sort) <(ls -d perfspect_* 2>/dev/null | sort))

    sudo tar -czf perfspect_int_${INSTANCE_TYPE}_results_${load_level}.tar.gz $NEW_DIRS
    aws s3 cp perfspect_int_${INSTANCE_TYPE}_results_${load_level}.tar.gz "s3://${S3_BUCKET}/${S3_PREFIX}/perfspect_int_${INSTANCE_TYPE}_results_${load_level}.tar.gz"
    sudo rm perfspect_int_${INSTANCE_TYPE}_results_${load_level}.tar.gz

    for dir in $NEW_DIRS; do
        sudo rm -rf "$dir"
    done
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
