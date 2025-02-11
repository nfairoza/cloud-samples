#!/bin/bash
S3_BUCKET="noortestdata"
S3_PREFIX="perfspect/amd-runs"

TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_TYPE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
CPU_COUNT=$(nproc)
if [ -d "perfspect" ]; then
  sudo rm -rf perfspect
fi

if [ -d "~/AMDPerfSpect" ]; then
    cd ~
    sudo rm -rf AMDPerfSpect.zip AMDPerfSpect/
    aws s3 cp s3://noortestdata/perfspect/AMDPerfSpect.zip .
    unzip AMDPerfSpect.zip
    cd AMDPerfSpect/python_amd_updated/perfspect/build
    sudo chmod +x perf-collect perf-postprocess
    cd ~
fi

BUILD_DIR=~/AMDPerfSpect/python_amd_updated/perfspect/build

collect_perfspect() {
    local load_level=$1
    local results_dir="${BUILD_DIR}/perfspect_${INSTANCE_TYPE}_results_${load_level}"

    mkdir -p ${results_dir}
    cd ${BUILD_DIR}
    echo ".................Running perf-collect................."
    sudo ./perf-collect -t 60 -c -o ${results_dir}/perfstat.csv

    cd ${results_dir}
    echo ".................Running perf-postprocess................."
    ${BUILD_DIR}/perf-postprocess

    cd ${BUILD_DIR}
    sudo tar -czf perfspect_${INSTANCE_TYPE}_results_${load_level}.tar.gz perfspect_${INSTANCE_TYPE}_results_${load_level}
    aws s3 cp perfspect_${INSTANCE_TYPE}_results_${load_level}.tar.gz "s3://${S3_BUCKET}/${S3_PREFIX}/perfspect_${INSTANCE_TYPE}_results_${load_level}.tar.gz"
    sudo rm -rf ${results_dir}
    sudo rm perfspect_${INSTANCE_TYPE}_results_${load_level}.tar.gz
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
