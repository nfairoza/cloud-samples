#!/bin/bash
set -e

REGION="us-east-2"
DATABASE_NAME="cur_reports"
S3_OUTPUT="s3://noortestdata/query_results/"
START_TIME="2023-01-01T00:00:00"
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CRAWLER_NAME="cur_report_crawler"
ROLE_NAME="AWSGlueServiceRole-crawler"
S3_PATH="s3://noortestdata/cur/cur-cca/data/"

echo "Checking if crawler exists..."
CRAWLER_EXISTS=$(aws glue get-crawler --name "$CRAWLER_NAME" --region $REGION 2>/dev/null || echo "false")

if [ "$CRAWLER_EXISTS" = "false" ]; then
    echo "Creating new crawler..."
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

    aws glue create-crawler \
        --name "$CRAWLER_NAME" \
        --role "$ROLE_ARN" \
        --database-name "$DATABASE_NAME" \
        --targets '{"S3Targets": [{"Path": "'"$S3_PATH"'", "Exclusions": []}]}' \
        --schema-change-policy '{"UpdateBehavior": "UPDATE_IN_DATABASE", "DeleteBehavior": "LOG"}' \
        --recrawl-policy '{"RecrawlBehavior": "CRAWL_EVERYTHING"}' \
        --configuration '{"Version":1.0,"CrawlerOutput":{"Partitions":{"AddOrUpdateBehavior":"InheritFromTable"},"Tables":{"AddOrUpdateBehavior":"MergeNewColumns"}}}' \
        --region "$REGION"
fi

echo "Starting crawler..."
aws glue start-crawler --name $CRAWLER_NAME --region $REGION >/dev/null

while true; do
    STATUS=$(aws glue get-crawler --name $CRAWLER_NAME --region $REGION --query 'Crawler.State' --output text)
    echo "Crawler status: $STATUS"
    if [ "$STATUS" = "READY" ]; then
        break
    fi
    sleep 10
done

echo "Getting table name..."
TABLES=$(aws glue get-tables --database-name $DATABASE_NAME --region $REGION --query 'TableList[*].Name' --output text)
if [ -z "$TABLES" ]; then
    echo "No tables found in database $DATABASE_NAME"
    exit 1
fi

echo "Available tables: $TABLES"
if echo "$TABLES" | grep -w "data" >/dev/null; then
    TABLE_NAME="data"
    echo "Found preferred table 'data'"
else
    TABLE_NAME=$(echo $TABLES | awk '{print $1}')
    echo "Preferred table 'data' not found, using first available table: $TABLE_NAME"
fi

echo "Running query..."
QUERY="WITH ranked_instances AS (
    SELECT
        line_item_resource_id as uuid,
        product_instance_type,
        REGEXP_REPLACE(line_item_availability_zone, '[a-z]$', '') as region,
        ROW_NUMBER() OVER (PARTITION BY line_item_resource_id ORDER BY line_item_usage_start_date DESC) as rn
    FROM
        ${DATABASE_NAME}.${TABLE_NAME}
    WHERE
        line_item_product_code = 'AmazonEC2'
        AND line_item_usage_type LIKE '%BoxUsage%'
        AND line_item_resource_id LIKE 'i-%'
)
SELECT uuid, product_instance_type, region
FROM ranked_instances
WHERE rn = 1"

EXECUTION_ID=$(aws athena start-query-execution \
    --query-string "$QUERY" \
    --work-group "primary" \
    --query-execution-context "Database=${DATABASE_NAME},Catalog=AwsDataCatalog" \
    --result-configuration "OutputLocation=${S3_OUTPUT}" \
    --region $REGION \
    --output text)

echo "Waiting for query completion..."
while true; do
    STATUS=$(aws athena get-query-execution --query-execution-id "$EXECUTION_ID" --region $REGION --query 'QueryExecution.Status.State' --output text)
    echo "Query status: $STATUS"
    if [ "$STATUS" = "SUCCEEDED" ]; then break; fi
    if [ "$STATUS" = "FAILED" ] || [ "$STATUS" = "CANCELLED" ]; then exit 1; fi
    sleep 5
done

echo "Downloading query results..."
RESULTS_LOCATION=$(aws athena get-query-execution --query-execution-id "$EXECUTION_ID" --region $REGION --query 'QueryExecution.ResultConfiguration.OutputLocation' --output text)
aws s3 cp "$RESULTS_LOCATION" "./cur_temp.csv" --region $REGION

echo "Creating resource analysis CSV..."
echo "uuid,cloud_csp,instance_type,region,max_cpu%,max_mem_used,max_network_bw,max_disk_bw_used,max_iops" > "resource_analysis.csv"

echo "Processing instances..."
while IFS=',' read -r uuid instance_type region; do
    uuid=$(echo "$uuid" | tr -d '"')
    instance_type=$(echo "$instance_type" | tr -d '"')
    region=$(echo "$region" | tr -d '"')

    echo "Processing instance: $uuid"

    get_max_metric() {
        local namespace=$1
        local metric_name=$2
        aws cloudwatch get-metric-statistics \
            --namespace "$namespace" \
            --metric-name "$metric_name" \
            --dimensions Name=InstanceId,Value="$uuid" \
            --start-time "$START_TIME" \
            --end-time "$END_TIME" \
            --period 86400 \
            --statistics Maximum \
            --region "$region" 2>/dev/null | \
        jq -r '.Datapoints[].Maximum | select(. != null)' | sort -rn | head -1
    }

    max_cpu=$(get_max_metric "AWS/EC2" "CPUUtilization")
    max_cpu=${max_cpu:-0}

    max_mem=$(get_max_metric "CWAgent" "mem_used_percent")
    max_mem=${max_mem:-0}

    max_net=$(get_max_metric "AWS/EC2" "NetworkOut")
    max_net=$(echo "$max_net" | awk '{printf "%.0f", $1/1024/1024}')
    max_net=${max_net:-0}

    max_disk_read=$(get_max_metric "AWS/EC2" "EBSReadBytes")
    max_disk_write=$(get_max_metric "AWS/EC2" "EBSWriteBytes")
    max_disk_read=${max_disk_read:-0}
    max_disk_write=${max_disk_write:-0}
    max_disk_total=$(echo "$max_disk_read $max_disk_write" | awk '{printf "%.0f", ($1+$2)/1024/1024}')

    max_iops_read=$(get_max_metric "AWS/EC2" "EBSReadOps")
    max_iops_write=$(get_max_metric "AWS/EC2" "EBSWriteOps")
    max_iops_read=${max_iops_read:-0}
    max_iops_write=${max_iops_write:-0}
    max_iops_total=$(echo "$max_iops_read $max_iops_write" | awk '{printf "%.0f", $1+$2}')

    printf "%s,AWS,%s,%s,%.2f,%.2f,%d,%d,%d\n" \
        "$uuid" "$instance_type" "$region" "$max_cpu" "$max_mem" "$max_net" "$max_disk_total" "$max_iops_total" >> "resource_analysis.csv"
done < <(tail -n +2 cur_temp.csv)

echo "Displaying results..."
cat resource_analysis.csv

echo "Cleaning up resources..."
aws glue delete-crawler --name "$CRAWLER_NAME" --region $REGION
rm -f "./cur_temp.csv"

echo "Script completed successfully and you can fine resource_analysis.csv in current directory"
