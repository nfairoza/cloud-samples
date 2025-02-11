#!/bin/bash

S3_BUCKET="noortestdata"
S3_PREFIX="perfspect/m7atests"

TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_TYPE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)

BUILD_DIR=~/perfspect/build
RESULTS_DIR="${BUILD_DIR}/perfspect_${INSTANCE_TYPE}_results"

mkdir -p ${RESULTS_DIR}

cd ${BUILD_DIR}
sudo ./perf-collect -t 60 -c -o ${RESULTS_DIR}/perfstat.csv

cd ${RESULTS_DIR}
${BUILD_DIR}/perf-postprocess

cd ${BUILD_DIR}
tar -czf perfspect_${INSTANCE_TYPE}_results.tar.gz perfspect_${INSTANCE_TYPE}_results

aws s3 cp perfspect_${INSTANCE_TYPE}_results.tar.gz "s3://${S3_BUCKET}/${S3_PREFIX}/perfspect_${INSTANCE_TYPE}_results.tar.gz"
rm -rf ${RESULTS_DIR}
rm perfspect_${INSTANCE_TYPE}_results.tar.gz
