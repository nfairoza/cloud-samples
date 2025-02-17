# EC2 Instance Analysis Script

This script automates the collection and analysis of EC2 instance metrics from AWS CloudWatch  and  Cost and Usage Report (CUR) data.

## Prerequisites

- AWS CLI installed and configured where the script is run.
- AWS CUR 2.0 data with resource ids in Parquet format stored in S3 bucket
- Required AWS IAM permissions:
  - AWS Glue (crawler operations)
  - Amazon Athena (query execution)
  - Amazon S3 (read/write access)
  - CloudWatch permissions:
    - cloudwatch:GetMetricStatistics
    - cloudwatch:GetMetricData
  - IAM role operations
- jq installed for JSON processing

## Configuration

Update these variables in the script according to your environment:

```bash
REGION="us-east-2"                                    # AWS region
DATABASE_NAME="cur_reports"                           # Glue database name
S3_OUTPUT="s3://noortestdata/query_results/"         # Query results output path
S3_PATH="s3://noortestdata/cur/cur-cca/data/"       # Source CUR data path
ROLE_NAME="AWSGlueServiceRole-crawler"               # IAM role for Glue crawler
START_TIME="2023-01-01T00:00:00"                     # Metrics collection start time
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

- uuid: Instance ID (CUR: line_item_resource_id)
- cloud_csp: Cloud provider ("AWS")
- instance_type: EC2 instance type (CUR: product_instance_type)
- region: AWS region (CUR: line_item_availability_zone)
- max_cpu%: Maximum CPU utilization (CloudWatch: AWS/EC2 namespace, CPUUtilization metric)
- max_mem_used: Memory usage (requires CloudWatch agent setup, if not configured 0)
- max_network_bw: Maximum network bandwidth in MB (CloudWatch: AWS/EC2 namespace, NetworkOut metric)
- max_disk_bw_used: Maximum disk bandwidth in MB (CloudWatch: AWS/EC2 namespace, sum of EBSReadBytes and EBSWriteBytes)
- max_iops: Maximum IOPS (CloudWatch: AWS/EC2 namespace, sum of EBSReadOps and EBSWriteOps)

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
