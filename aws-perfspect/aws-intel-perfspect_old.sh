#!/bin/bash

S3_BUCKET="noortestdata"
S3_PREFIX="perfspect/m7itests"

TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_TYPE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)

if [ ! -d "perfspect" ]; then
   wget -qO- https://github.com/intel/PerfSpect/releases/latest/download/perfspect.tgz | tar xvz
fi

cd perfspect
chmod +x perfspect

OLD_DIRS=$(ls -d perfspect_* 2>/dev/null)

sudo ./perfspect report
sudo ./perfspect metrics --duration 60
sudo ./perfspect flame
sudo ./perfspect telemetry --duration 60
sudo ./perfspect lock

NEW_DIRS=$(comm -13 <(echo "$OLD_DIRS" | sort) <(ls -d perfspect_* 2>/dev/null | sort))

tar -czf perfspect_${INSTANCE_TYPE}_results.tar.gz $NEW_DIRS

aws s3 cp perfspect_${INSTANCE_TYPE}_results.tar.gz "s3://${S3_BUCKET}/${S3_PREFIX}/perfspect_${INSTANCE_TYPE}_results.tar.gz"

rm perfspect_${INSTANCE_TYPE}_results.tar.gz
