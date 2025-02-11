# AWS CLI AMD EC2 Instance Management Guide

## Overview

This guide provides AWS CLI commands for managing AMD-based EC2 instances.


#### Notes
- Replace placeholder values (ami-12345678, i-1234567890, my-sg etc.) with your actual resource IDs

## Instance Management

### Basic Operations

```bash
# List all running AMD instances
aws ec2 describe-instances \
    --filters "Name=instance-type,Values=*6a.*" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' \
    --output table

# Launch basic AMD instance
aws ec2 run-instances \
    --image-id ami-12345678 \
    --instance-type m7a.large \
    --count 1 \
    --key-name my-key-pair \
    --security-group-ids my-sg

# Stop multiple instances of specific type
aws ec2 describe-instances \
    --filters "Name=instance-type,Values=m6a.2xlarge" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text | xargs aws ec2 stop-instances --instance-ids
```

### Advanced Instance Configuration

```bash
# Create optimized AMI
aws ec2 create-image \
    --instance-id i-1234567890abcdef0 \
    --name "AMD-Optimized-$(date +%Y%m%d)" \
    --description "AMD instance with optimized hardware settings" \
    --no-reboot

# Create launch template with hardware specs
aws ec2 create-launch-template \
    --launch-template-name "AMD-Compute-Optimized" \
    --version-description "AMD instances with specific hardware config" \
    --launch-template-data '{"InstanceType":"m6a.2xlarge","CpuOptions":{"CoreCount":4,"ThreadsPerCore":2}}'

# Launch instance with custom storage
aws ec2 run-instances \
    --image-id ami-12345678 \
    --instance-type r7a.2xlarge \
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":100,\"VolumeType\":\"gp3\",\"Iops\":3000,\"Throughput\":125,\"DeleteOnTermination\":true}}]"
```

## CPU Configuration

### Basic CPU Operations

```bash
# Get CPU configuration details
aws ec2 describe-instance-types \
    --instance-types m6a.2xlarge \
    --query 'InstanceTypes[].{Type:InstanceType,vCPUs:VCpuInfo.DefaultVCpus,CoreCount:VCpuInfo.DefaultCores}'

# Check SMT status
aws ec2 describe-instances \
    --instance-ids i-1234567890abcdef0 \
    --query 'Reservations[].Instances[].CpuOptions'

# Modify CPU credits (T3a instances)
aws ec2 modify-instance-credit-specification \
    --instance-credit-specifications "InstanceId=i-1234567890,CpuCredits=unlimited"
```

### Advanced CPU Configuration

```bash
# Launch AMD instance with SMT enabled
aws ec2 run-instances \
    --image-id ami-12345678 \
    --instance-type m6a.2xlarge \
    --cpu-options "CoreCount=4,ThreadsPerCore=2" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=AMD-Test}]'

# Launch instance with SMT disabled
aws ec2 run-instances \
    --image-id ami-12345678 \
    --instance-type m6a.4xlarge \
    --cpu-options "CoreCount=8,ThreadsPerCore=1"

# Configure advanced CPU options
aws ec2 run-instances \
    --image-id ami-12345678 \
    --instance-type t3a.large \
    --cpu-options "CoreCount=2,ThreadsPerCore=2" \
    --placement "Tenancy=dedicated" \
    --monitoring "Enabled=true"
```

## Memory Management

### Basic Memory Monitoring

```bash
# Monitor basic memory metrics
aws cloudwatch get-metric-statistics \
    --namespace CWAgent \
    --metric-name mem_used_percent \
    --dimensions Name=InstanceId,Value=i-1234567890 \
    --start-time $(date -u +%Y-%m-%dT%H:%M:%S -d '1 hour ago') \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --statistics Average

# Get instance metadata (including memory)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query 'Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,CPU:CpuOptions,AZ:Placement.AvailabilityZone}'
```

### Advanced Memory Configuration

```bash
# Configure CloudWatch agent for detailed memory metrics
aws ssm send-command \
    --document-name "AWS-ConfigureAWSPackage" \
    --parameters '{"Action":["Install"],"Name":["AmazonCloudWatchAgent"]}' \
    --targets "Key=instanceids,Values=i-1234567890"

# Set up memory utilization alarm
aws cloudwatch put-metric-alarm \
    --alarm-name high-memory-utilization \
    --alarm-description "Memory exceeds 80%" \
    --metric-name mem_used_percent \
    --namespace CWAgent \
    --dimensions Name=InstanceId,Value=i-1234567890 \
    --period 300 \
    --evaluation-periods 2 \
    --threshold 80 \
    --comparison-operator GreaterThanThreshold \
    --statistic Average
```
