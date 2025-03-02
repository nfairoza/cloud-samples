#!/bin/bash
set -e
# Time range
DAYS_LOOKBACK=5                 # 5 days lookback because 1440 datapoint for cloudwatch to not hit API limits. If you need to go further back you need to change the duratio to 1 hour.
# CloudWatch period (in seconds)
HIGH_RES_PERIOD=300             # 5 minutes in seconds

# Calculate timestamps
HIGH_RES_START_TIME=$(date -u -d "$DAYS_LOOKBACK days ago" +"%Y-%m-%dT%H:%M:%SZ")
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Using 5-minute resolution for all metrics for the past $DAYS_LOOKBACK days"

echo "Creating EIA data CSV..."
echo "uuid,cloud_csp,instance type,region,max cpu%,max mem used,max network bw,max disk bw used,max iops" > "eia_data.csv"

echo "Getting list of all AWS regions..."
REGIONS=$(aws ec2 describe-regions --query "Regions[].RegionName" --output text)

for REGION in $REGIONS; do
    echo "Processing region: $REGION"

    echo "Getting instances from EC2 in $REGION..."
    INSTANCES=$(aws ec2 describe-instances --region $REGION --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,Placement.AvailabilityZone]' --output text)

    if [ -z "$INSTANCES" ]; then
        echo "****************** No instances found in region $REGION"
        continue
    fi

    echo "****************** Processing instances in $REGION ******************"
    while read -r uuid instance_type az; do
        region=$(echo "$az" | sed 's/[a-z]$//')

        echo "...||| Processing instance: $uuid in $region |||..."

        get_metrics() {
            local namespace=$1
            local metric_name=$2
            local data=$(aws cloudwatch get-metric-statistics \
                --namespace "$namespace" \
                --metric-name "$metric_name" \
                --dimensions Name=InstanceId,Value="$uuid" \
                --start-time "$HIGH_RES_START_TIME" \
                --end-time "$END_TIME" \
                --period $HIGH_RES_PERIOD \
                --statistics Maximum \
                --region "$region" 2>/dev/null || echo '{"Datapoints":[]}')

            local max_value=$(echo "$data" | jq -r '.Datapoints[].Maximum | select(. != null)' | sort -rn | head -1 || echo "0")
            echo "${max_value:-0}"
        }


        max_cpu=$(get_metrics "AWS/EC2" "CPUUtilization")
        echo "  CPU max: $max_cpu% (from 5-minute resolution data)"

        mem_used_bytes=$(get_metrics "CWAgent" "mem_used")

        if [ -n "$mem_used_bytes" ] && [ "$mem_used_bytes" != "0" ]; then
            # Used 2 decimal points for memory in GB
            max_mem=$(echo "$mem_used_bytes" | awk '{printf "%.2f", $1/(1024*1024*1024)}')
            echo "  Memory used: $max_mem GB (from raw bytes: $mem_used_bytes, 5-minute resolution)"
        else
                max_mem="0.00"
                echo "  No memory metrics available for this instance. Please configure CloudWatch to publish Memory metrics in namespace CWAgent"

        fi


        # Formula : Total Network Bandwidth (Mbps) = (NetworkIn + NetworkOut) × 8 / (time period in seconds × 10^6)
        # Get network usage (5-minute resolution)
        max_net_bytes_out=$(get_metrics "AWS/EC2" "NetworkOut")
        max_net_bytes_in=$(get_metrics "AWS/EC2" "NetworkIn")
        max_net=$(echo "$max_net_bytes_out $max_net_bytes_in" | awk '{printf "%.8f", (($1 + $2) * 8) / (300 * 1000000)}')


        echo "  Network max burst: $max_net Mbps (from 5-minute period, raw bytes out: $max_net_bytes_out, raw bytes in: $max_net_bytes_in)"

        max_disk_read=$(get_metrics "AWS/EC2" "EBSReadBytes")
        max_disk_write=$(get_metrics "AWS/EC2" "EBSWriteBytes")
        max_disk_total=$(echo "$max_disk_read $max_disk_write" | awk '{printf "%.0f", ($1+$2)/1024/1024}')
        echo "  Disk bandwidth: $max_disk_total MB (from 5-minute resolution data)"

        max_iops_read=$(get_metrics "AWS/EC2" "EBSReadOps")
        max_iops_write=$(get_metrics "AWS/EC2" "EBSWriteOps")
        max_iops_total=$(echo "$max_iops_read $max_iops_write" | awk '{printf "%.0f", $1+$2}')
        echo "  IOPS: $max_iops_total (from 5-minute resolution data)"

        printf "%s,AWS,%s,%s,%.2f,%.2f,%.8f,%d,%d\n" \
            "$uuid" "$instance_type" "$region" "$max_cpu" "$max_mem" "$max_net" "$max_disk_total" "$max_iops_total" >> "eia_data.csv"
    done <<< "$INSTANCES"
done

# echo "Displaying results..."
# cat eia_data.csv

echo "Script completed successfully and you can find eia_data.csv in current directory"
