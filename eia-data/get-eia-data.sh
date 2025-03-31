#!/bin/bash
set -e
# Time range
DAYS_LOOKBACK=1                # 5 days lookback because 1440 datapoint for cloudwatch to not hit API limits. If you need to go further back you need to change the duratio to 1 hour.
# CloudWatch period (in seconds)
HIGH_RES_PERIOD=60             # 5 minutes in seconds

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
        echo "  CPU max: $max_cpu% "


        mem_used_bytes=$(get_metrics "CWAgent" "mem_used")
        mem_cached_bytes=$(get_metrics "CWAgent" "mem_cached")
        mem_buffered_bytes=$(get_metrics "CWAgent" "mem_buffered")
        mem_slab_bytes=$(get_metrics "CWAgent" "mem_slab")

        total_used_bytes=$(echo "$mem_used_bytes $mem_cached_bytes $mem_buffered_bytes $mem_slab_bytes" | awk '{print $1 + $2 + $3 + $4}')

        if [ -n "$mem_used_bytes" ] && [ "$mem_used_bytes" != "0" ]; then
            # Used 2 decimal points for memory
            max_mem=$(echo "$total_used_bytes" | awk '{printf "%.2f", $1/(1024*1024*1024)}')
            echo "  Memory used: $max_mem GB (from raw bytes: $total_used_bytes)"
        else
                max_mem="0.00"
                echo "  No memory metrics available for this instance. Please configure CloudWatch to publish Memory metrics in namespace CWAgent"

        fi


        # Formula : Total Network Bandwidth (Mbps) = (NetworkIn + NetworkOut) × 8 / (time period in seconds × 10^6)
        # Get network metrics
        max_net_bytes_out=$(get_metrics "AWS/EC2" "NetworkOut")
        max_net_bytes_in=$(get_metrics "AWS/EC2" "NetworkIn")


        if [[ "$max_net_bytes_out" == "0" && "$max_net_bytes_in" == "0" ]]; then
            max_net="0.00"
        else
            max_net=$(echo "$max_net_bytes_out $max_net_bytes_in $HIGH_RES_PERIOD" | \
                      awk '{printf "%.8f", (($1 + $2) * 8) / ($3 * 1000000)}')
        fi

        echo "  Network max burst: $max_net Mbps (from ${HIGH_RES_PERIOD}-second period, raw bytes out: $max_net_bytes_out, raw bytes in: $max_net_bytes_in)"


        # Get disk metrics
        max_ebs_read=$(get_metrics "AWS/EC2" "EBSReadBytes")
        max_ebs_write=$(get_metrics "AWS/EC2" "EBSWriteBytes")
        max_disk_read=$(get_metrics "AWS/EC2" "DiskReadBytes")
        max_disk_write=$(get_metrics "AWS/EC2" "DiskWriteBytes")

        # Sum all disk metrics
        max_disk_bytes_total=$(echo "$max_ebs_read $max_ebs_write $max_disk_read $max_disk_write" | \
                           awk '{print $1 + $2 + $3 + $4}')

        # Convert to MB/s using Datadog formula and divide by duration
        max_disk_total=$(echo "$max_disk_bytes_total $HIGH_RES_PERIOD" | \
                        awk '{printf "%.2f", $1 / (1024 * 1024 * $2)}')

        echo "  Disk bandwidth: $max_disk_total MB/s (from combined EBS and Disk metrics, divided by ${HIGH_RES_PERIOD}-second period)"

        # Get IOPS metrics
        max_ebs_read_ops=$(get_metrics "AWS/EC2" "EBSReadOps")
        max_ebs_write_ops=$(get_metrics "AWS/EC2" "EBSWriteOps")
        max_disk_read_ops=$(get_metrics "AWS/EC2" "DiskReadOps")
        max_disk_write_ops=$(get_metrics "AWS/EC2" "DiskWriteOps")

        # Sum all IOPS metrics and divide by duration
        max_iops_total=$(echo "$max_ebs_read_ops $max_ebs_write_ops $max_disk_read_ops $max_disk_write_ops $HIGH_RES_PERIOD" | \
                        awk '{printf "%.0f", ($1 + $2 + $3 + $4) / $5}')

        echo "  IOPS: $max_iops_total (operations per second, combined from EBS and Disk metrics, divided by ${HIGH_RES_PERIOD}-second period)"


        printf "%s,AWS,%s,%s,%.2f,%.2f,%.8f,%.2f,%d\n" \
    "$uuid" "$instance_type" "$region" "$max_cpu" "$max_mem" "$max_net" "$max_disk_total" "$max_iops_total" >> "eia_data.csv"
    done <<< "$INSTANCES"
done
echo "Displaying results..."
cat eia_data.csv
echo "Script completed successfully and you can find eia_data.csv in current directory"
