#!/bin/bash
set -e

# Configuration - Update these variables for your environment
REGION="us-east-2"
DATABASE_NAME="cur_legacy_reports"
CRAWLER_NAME="cur_legacy_crawler"
S3_PATH="s3://your-bucket-name/your-cur-prefix/"  # Path to CUR legacy data
S3_OUTPUT="s3://your-bucket-name/query_results/"
ROLE_NAME="AWSGlueServiceRole-crawler"

echo "========================================="
echo "AWS CUR Legacy Export Script for CCA"
echo "========================================="

# Get IAM Role ARN
echo "Retrieving IAM Role ARN..."
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null)

if [ -z "$ROLE_ARN" ]; then
    echo "Error: IAM role '$ROLE_NAME' not found."
    echo "Please create the role or update ROLE_NAME variable."
    exit 1
fi

echo "Using IAM Role: $ROLE_ARN"

# Create Glue Database if it doesn't exist
if ! aws glue get-database --name "$DATABASE_NAME" --region "$REGION" &>/dev/null; then
    echo "Creating Glue database: $DATABASE_NAME"
    aws glue create-database \
        --database-input "{\"Name\": \"$DATABASE_NAME\"}" \
        --region $REGION
else
    echo "Database '$DATABASE_NAME' already exists."
fi

# Create or skip Glue Crawler
if ! aws glue get-crawler --name "$CRAWLER_NAME" --region "$REGION" &>/dev/null; then
    echo "Creating Glue crawler for CUR Legacy data..."
    aws glue create-crawler \
        --name $CRAWLER_NAME \
        --role "$ROLE_ARN" \
        --database-name $DATABASE_NAME \
        --targets "{\"S3Targets\": [{\"Path\": \"$S3_PATH\"}]}" \
        --schema-change-policy "{\"UpdateBehavior\": \"UPDATE_IN_DATABASE\", \"DeleteBehavior\": \"LOG\"}" \
        --recrawl-policy "{\"RecrawlBehavior\": \"CRAWL_EVERYTHING\"}" \
        --configuration "{\"Version\":1.0,\"CrawlerOutput\":{\"Partitions\":{\"AddOrUpdateBehavior\":\"InheritFromTable\"},\"Tables\":{\"AddOrUpdateBehavior\":\"MergeNewColumns\"}}}" \
        --region $REGION
    echo "Crawler created successfully."
else
    echo "Crawler '$CRAWLER_NAME' already exists."
fi

# Start Crawler
echo "Starting crawler to catalog CUR data..."
if aws glue start-crawler --name $CRAWLER_NAME --region $REGION 2>&1 | grep -q "CrawlerRunningException"; then
    echo "Crawler is already running. Waiting for completion..."
else
    echo "Crawler started."
fi

# Wait for crawler to complete
echo "Waiting for crawler to complete..."
while true; do
    STATUS=$(aws glue get-crawler --name $CRAWLER_NAME --region $REGION --query 'Crawler.State' --output text)
    echo "Crawler status: $STATUS"
    if [ "$STATUS" = "READY" ]; then
        echo "Crawler completed successfully."
        break
    fi
    sleep 10
done

# Get table name from cataloged data
echo "Retrieving table information..."
TABLES=$(aws glue get-tables --database-name $DATABASE_NAME --region $REGION --query 'TableList[*].Name' --output text)
echo "Available tables: $TABLES"


TABLE_NAME=$(echo "$TABLES" | awk '{print $1}')

if [ -z "$TABLE_NAME" ]; then
    echo "Error: No tables found in database '$DATABASE_NAME'."
    echo "Please verify your S3 path contains CUR data and try again."
    exit 1
fi

echo "Using table: $TABLE_NAME"

echo "Running Athena query for CUR Legacy data..."
QUERY="SELECT
   'AWS' as Cloud,
   REGEXP_REPLACE(availability_zone, '[a-z]\$', '') as Region,
   product_instance_type as Size,
   COUNT(DISTINCT resource_id) as Quantity,
   CAST(SUM(usage_amount) as INTEGER) as \"Total number of hours per month\",
   CASE
       WHEN reserved_instance_arn != '' THEN 'Reserved'
       WHEN pricing_term = 'Spot' THEN 'Spot'
       ELSE 'On-Demand'
   END as \"Pricing Model\"
FROM
   ${DATABASE_NAME}.${TABLE_NAME}
WHERE
   line_item_type = 'Usage'
   AND product_code = 'AmazonEC2'
   AND usage_type LIKE '%BoxUsage%'
   AND product_instance_type != ''
   AND year = CAST(YEAR(DATE_ADD('month', -1, CURRENT_DATE)) AS VARCHAR)
   AND month = LPAD(CAST(MONTH(DATE_ADD('month', -1, CURRENT_DATE)) AS VARCHAR), 2, '0')
GROUP BY
   availability_zone,
   product_instance_type,
   reserved_instance_arn,
   pricing_term
ORDER BY
   Size,
   Region,
   \"Pricing Model\""

# Execute Athena Query
EXECUTION_ID=$(aws athena start-query-execution \
    --query-string "$QUERY" \
    --work-group "primary" \
    --query-execution-context "Database=${DATABASE_NAME},Catalog=AwsDataCatalog" \
    --result-configuration "OutputLocation=${S3_OUTPUT}" \
    --region $REGION \
    --output text)

echo "Query execution ID: $EXECUTION_ID"

# Monitor query execution
echo "Monitoring query execution..."
while true; do
    STATUS=$(aws athena get-query-execution \
        --query-execution-id "$EXECUTION_ID" \
        --region $REGION \
        --query 'QueryExecution.Status.State' \
        --output text)

    echo "Query status: $STATUS"

    if [ "$STATUS" = "SUCCEEDED" ]; then
        echo "Query completed successfully!"
        break
    elif [ "$STATUS" = "FAILED" ] || [ "$STATUS" = "CANCELLED" ]; then
        ERROR_MESSAGE=$(aws athena get-query-execution \
            --query-execution-id "$EXECUTION_ID" \
            --region $REGION \
            --query 'QueryExecution.Status.StateChangeReason' \
            --output text)
        echo "Error: Query failed with message: $ERROR_MESSAGE"
        echo ""
        echo "Common issues with CUR Legacy:"
        echo "1. Column names may vary - check your CUR schema"
        echo "2. Resource ID may not be enabled in your CUR report"
        echo "3. Table structure might be different based on CUR version"
        echo ""
        echo "Full query execution details:"
        aws athena get-query-execution --query-execution-id "$EXECUTION_ID" --region $REGION
        exit 1
    fi
    sleep 5
done

# Get results location
RESULTS_LOCATION=$(aws athena get-query-execution \
    --query-execution-id "$EXECUTION_ID" \
    --region $REGION \
    --query 'QueryExecution.ResultConfiguration.OutputLocation' \
    --output text)

# Download results
echo "Downloading results..."
aws s3 cp "$RESULTS_LOCATION" "./cur_legacy_results.csv" --region $REGION
echo ""
echo "========================================="
echo "Success! Results saved to: cur_legacy_results.csv"
echo "========================================="
echo ""
echo "Note: Crawler remains active for future use."
echo "To delete crawler, run:"
echo "aws glue delete-crawler --name $CRAWLER_NAME --region $REGION"
