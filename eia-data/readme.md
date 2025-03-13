# EC2 Instance Analysis Script

This script automates the collection and analysis of EC2 instance metrics from AWS CloudWatch  and  Cost and Usage Report (CUR) data.

## Prerequisites

- AWS CLI installed and configured where the script is run.
- Required AWS IAM permissions:
  - CloudWatch permissions:
    - cloudwatch:GetMetricStatistics
    - cloudwatch:GetMetricData
  - IAM role operations
  - EC2 permissions:
    - ec2:DescribeInstances
    - ec2:DescribeInstanceTypes
- jq installed for JSON processing

## Configuration

Optionally you can change these variables in the script according to your environment:

```bash
# Time range
DAYS_LOOKBACK=5                 # 5 days lookback because 1440 datapoint for cloudwatch to not hit API limits. If you need to go further back you need to change the duratio to 1 hour.
# CloudWatch period (in seconds)
HIGH_RES_PERIOD=300             # 5 minutes in seconds
                    # Metrics collection start time
```

## Usage

1. Download the script:
```bash
wget https://raw.githubusercontent.com/your-repo/get-eia-data.sh
```

2. Make the script executable:
```bash
chmod +x get-eia-data.sh
```

3. Run the script:
```bash
./get-eia-data.sh
```

## Output Format and Metric Details

The script generates a CSV file named `eia_data.csv` with the following columns:

- uuid: Instance ID (EC2 instance identifier)
- cloud_csp: Cloud provider (hardcoded as "AWS")
- instance_type: EC2 instance type (from EC2 describe-instances)
- region: AWS region (extracted from availability zone)
- max_cpu%: Maximum CPU utilization percentage (CloudWatch: AWS/EC2 namespace, CPUUtilization metric, Maximum statistic)
- max_mem_used: Maximum memory usage in GB (CloudWatch: CWAgent namespace, mem_used metric, Maximum statistic)
- max_network_bw: Maximum network bandwidth in Mbps calculated as (NetworkIn + NetworkOut) × 8 / (300 × 10^6) (CloudWatch: AWS/EC2 namespace, NetworkIn and NetworkOut metrics)
- max_disk_bw_used: Maximum disk bandwidth in MB calculated as (EBSReadBytes + EBSWriteBytes)/1024/1024 (CloudWatch: AWS/EC2 namespace, EBSReadBytes and EBSWriteBytes metrics)
- max_iops: Maximum IOPS calculated as EBSReadOps + EBSWriteOps (CloudWatch: AWS/EC2 namespace, EBSReadOps and EBSWriteOps metrics)

## Memory Metric Requirements

- Memory metrics require CloudWatch agent installation
- EBS metrics require attached volumes
- Some metrics may not be available for terminated instances

### Setting Up CloudWatch Agent for Memory Metrics

To enable memory metrics collection, install and configure the CloudWatch agent on each EC2 instance:

```bash
sudo apt-get update
sudo apt-get install -y collectd
wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
sudo dpkg -i amazon-cloudwatch-agent.deb

TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)


sudo tee /opt/aws/amazon-cloudwatch-agent/bin/config.json << 'EOF'
{
    "agent": {
        "metrics_collection_interval": 60
    },
    "metrics": {
        "metrics_collected": {
            "mem": {
                "measurement": [
                    "used",
                    "used_percent",
                    "total"
                ]
            }
        },
        "append_dimensions": {
            "InstanceId": "${aws:InstanceId}"
        }
    }
}
EOF

# Restart agent with new configuration
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a stop
sudo rm -f /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.toml
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a start
```

## Cleanup Notes

The script automatically:
- Removes the Glue crawler after execution
- Cleans up temporary query results

## Notes

CloudWatch retains metric data as follows:
* Data points with a period of less than 60 seconds are available for 3 hours. These data points are high-resolution custom metrics.(extra config and charge)
* Data points with a period of 60 seconds (1 minute) are available for 15 days
* Data points with a period of 300 seconds (5 minutes) are available for 63 days
* Data points with a period of 3600 seconds (1 hour) are available for 455 days (15 months)

aws ec2 describe-instances only returns instances in the following states:
* running
* pending
* stopping
* stopped
