#!/bin/bash
set -e

REGION="us-east-2"
DATABASE_NAME="cur_reports"
CRAWLER_NAME="cur_report_crawler"
S3_PATH="s3://noortestdata/cur/cur-cca/data/"
S3_OUTPUT="s3://noortestdata/query_results/"
ROLE_NAME="AWSGlueServiceRole-crawler"

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

if ! aws glue get-crawler --name "$CRAWLER_NAME" --region "$REGION" &>/dev/null; then
    echo "Creating crawler with given S3 path..."
    aws glue create-crawler \
        --name $CRAWLER_NAME \
        --role "$ROLE_ARN" \
        --database-name $DATABASE_NAME \
        --targets "{\"S3Targets\": [{\"Path\": \"$S3_PATH\", \"Exclusions\": []}]}" \
        --schema-change-policy "{\"UpdateBehavior\": \"UPDATE_IN_DATABASE\", \"DeleteBehavior\": \"LOG\"}" \
        --recrawl-policy "{\"RecrawlBehavior\": \"CRAWL_EVERYTHING\"}" \
        --configuration "{\"Version\":1.0,\"CrawlerOutput\":{\"Partitions\":{\"AddOrUpdateBehavior\":\"InheritFromTable\"},\"Tables\":{\"AddOrUpdateBehavior\":\"MergeNewColumns\"}}}" \
        --region $REGION
else
    echo "Crawler already exists, skipping creation..."
fi

echo "Starting crawler..."
aws glue start-crawler --name $CRAWLER_NAME --region $REGION

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
echo "Available tables: $TABLES"


if echo "$TABLES" | grep -q "\bdata\b"; then
    TABLE_NAME="data"
else
    echo "No 'data' table found. Available tables: $TABLES"
    exit 1
fi

echo "Using table: $TABLE_NAME"

echo "Running query..."
QUERY="SELECT
   'AWS' as Cloud,
   REGEXP_REPLACE(line_item_availability_zone, '[a-z]$', '') as Region,
   product_instance_type as Size,
   COUNT(DISTINCT line_item_resource_id) as Quantity,
   CAST(SUM(line_item_usage_amount) as INTEGER) as \"Total number of hours per month\",
   CASE
       WHEN pricing_purchase_option = 'Reserved' THEN 'Reserved'
       WHEN pricing_purchase_option = 'Spot' THEN 'Spot'
       ELSE 'On-Demand'
   END as \"Pricing Model\"
FROM
   ${DATABASE_NAME}.${TABLE_NAME}
WHERE
   line_item_line_item_type = 'Usage'
   AND line_item_product_code = 'AmazonEC2'
   AND line_item_usage_type LIKE '%BoxUsage%'
GROUP BY
   line_item_availability_zone,
   product_instance_type,
   pricing_purchase_option
ORDER BY
   Size,
   Region,
   \"Pricing Model\""

EXECUTION_ID=$(aws athena start-query-execution \
    --query-string "$QUERY" \
    --work-group "primary" \
    --query-execution-context "Database=${DATABASE_NAME},Catalog=AwsDataCatalog" \
    --result-configuration "OutputLocation=${S3_OUTPUT}" \
    --region $REGION \
    --output text)

echo "Query execution ID: $EXECUTION_ID"

while true; do
    STATUS=$(aws athena get-query-execution \
        --query-execution-id "$EXECUTION_ID" \
        --region $REGION \
        --query 'QueryExecution.Status.State' \
        --output text)

    echo "Query status: $STATUS"
    if [ "$STATUS" = "SUCCEEDED" ]; then
        break
    elif [ "$STATUS" = "FAILED" ] || [ "$STATUS" = "CANCELLED" ]; then
        ERROR_MESSAGE=$(aws athena get-query-execution \
            --query-execution-id "$EXECUTION_ID" \
            --region $REGION \
            --query 'QueryExecution.Status.StateChangeReason' \
            --output text)
        echo "Query failed: $ERROR_MESSAGE"
        aws athena get-query-execution --query-execution-id "$EXECUTION_ID" --region $REGION
        exit 1
    fi
    sleep 5
done

RESULTS_LOCATION=$(aws athena get-query-execution \
    --query-execution-id "$EXECUTION_ID" \
    --region $REGION \
    --query 'QueryExecution.ResultConfiguration.OutputLocation' \
    --output text)


echo "Clean up: Deleting existing crawler..."
aws glue delete-crawler --name "$CRAWLER_NAME" --region $REGION || true

aws s3 cp "$RESULTS_LOCATION" "./cur_results.csv" --region $REGION
echo "Results downloaded to cur_results.csv"
