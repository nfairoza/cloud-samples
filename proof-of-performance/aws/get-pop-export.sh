#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Proof of Performance - AWS export (CUR 2.0 / Data Exports)
# =============================================================================
# Pulls 12 months of EC2 usage from your Cost & Usage Report, classifies every
# instance family as Intel / AMD / ARM(Graviton), and writes a normalized CSV:
#
#   cloud,year,month,region,arch,family,vcpu_hours,vcpus
#
# vcpu_hours = SUM(usage_hours x product_vcpu)                 (consumption)
# vcpus      = provisioned vCPUs that month = SUM over DISTINCT instances
#              (line_item_resource_id) of each instance's product_vcpu (real count)
#
# Then (if python3 is available) builds the multi-sheet Excel report via
# ../build_report.py.
#
# Methodology mirrors ../../cca-export/aws (Glue crawler -> Athena -> download).
# =============================================================================

# ------------------------- Configuration (EDIT ME) ---------------------------
REGION="us-east-2"
DATABASE_NAME="cur_reports"                             # Glue DB (must already exist)
CRAWLER_NAME="pop_cur_crawler"                          # Glue crawler name
S3_PATH="s3://your-bucket-name/your-cur-prefix/data/"   # Source CUR (Parquet) path
S3_OUTPUT="s3://your-bucket-name/query_results/"        # Athena results path
ROLE_NAME="AWSGlueServiceRole-crawler"                  # IAM role for the crawler
LONG_CSV="./aws_pop_long.csv"                           # normalized output
REPORT_XLSX="./pop_report.xlsx"                         # final Excel (if python3)
# -----------------------------------------------------------------------------

echo "========================================="
echo " Proof of Performance - AWS export"
echo "========================================="

command -v aws >/dev/null 2>&1 || { echo "ERROR: AWS CLI not installed."; exit 1; }

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

# ---- Ensure the Glue database exists ----------------------------------------
if ! aws glue get-database --name "$DATABASE_NAME" --region "$REGION" >/dev/null 2>&1; then
    echo "Creating Glue database: $DATABASE_NAME"
    aws glue create-database --database-input "{\"Name\": \"$DATABASE_NAME\"}" --region "$REGION"
fi

# ---- Create the crawler if needed -------------------------------------------
if ! aws glue get-crawler --name "$CRAWLER_NAME" --region "$REGION" >/dev/null 2>&1; then
    echo "Creating crawler for CUR data..."
    aws glue create-crawler \
        --name "$CRAWLER_NAME" \
        --role "$ROLE_ARN" \
        --database-name "$DATABASE_NAME" \
        --targets "{\"S3Targets\": [{\"Path\": \"$S3_PATH\", \"Exclusions\": []}]}" \
        --schema-change-policy "{\"UpdateBehavior\": \"UPDATE_IN_DATABASE\", \"DeleteBehavior\": \"LOG\"}" \
        --recrawl-policy "{\"RecrawlBehavior\": \"CRAWL_EVERYTHING\"}" \
        --configuration "{\"Version\":1.0,\"CrawlerOutput\":{\"Partitions\":{\"AddOrUpdateBehavior\":\"InheritFromTable\"},\"Tables\":{\"AddOrUpdateBehavior\":\"MergeNewColumns\"}}}" \
        --region "$REGION"
else
    echo "Crawler already exists, skipping creation..."
fi

echo "Starting crawler..."
aws glue start-crawler --name "$CRAWLER_NAME" --region "$REGION" 2>/dev/null || true
while true; do
    STATUS=$(aws glue get-crawler --name "$CRAWLER_NAME" --region "$REGION" --query 'Crawler.State' --output text)
    echo "Crawler status: $STATUS"
    [ "$STATUS" = "READY" ] && break
    sleep 10
done

# ---- Resolve the table name -------------------------------------------------
TABLES=$(aws glue get-tables --database-name "$DATABASE_NAME" --region "$REGION" --query 'TableList[*].Name' --output text)
echo "Available tables: $TABLES"
if echo "$TABLES" | grep -qw "data"; then
    TABLE_NAME="data"
else
    TABLE_NAME=$(echo "$TABLES" | awk '{print $1}')
fi
[ -z "$TABLE_NAME" ] && { echo "ERROR: no table found in $DATABASE_NAME"; exit 1; }
echo "Using table: $TABLE_NAME"

# ---- Build and run the Athena query -----------------------------------------
QUERY="WITH per_instance AS (
    SELECT
        CAST(year AS INTEGER) AS year,
        CAST(month AS INTEGER) AS month,
        REGEXP_REPLACE(line_item_availability_zone, '[a-z]\$', '') AS region,
        CASE
            WHEN split_part(product_instance_type, '.', 1) = 'a1' THEN 'ARM'
            WHEN regexp_like(split_part(product_instance_type, '.', 1), '[0-9][a-z]*g[a-z]*\$') THEN 'ARM'
            WHEN regexp_like(split_part(product_instance_type, '.', 1), '[0-9][a-z]*a[a-z]*\$') THEN 'AMD'
            ELSE 'Intel'
        END AS arch,
        split_part(product_instance_type, '.', 1) AS family,
        line_item_resource_id AS resource_id,
        MAX(TRY_CAST(product_vcpu AS DOUBLE)) AS inst_vcpus,
        SUM(line_item_usage_amount * TRY_CAST(product_vcpu AS DOUBLE)) AS inst_vcpu_hours
    FROM ${DATABASE_NAME}.${TABLE_NAME}
    WHERE line_item_line_item_type = 'Usage'
        AND line_item_product_code = 'AmazonEC2'
        AND line_item_usage_type LIKE '%BoxUsage%'
        AND TRY_CAST(product_vcpu AS DOUBLE) > 0
        AND (CAST(year AS INTEGER)*100 + CAST(month AS INTEGER)) >= (YEAR(DATE_ADD('month',-12,CURRENT_DATE))*100 + MONTH(DATE_ADD('month',-12,CURRENT_DATE)))
        AND (CAST(year AS INTEGER)*100 + CAST(month AS INTEGER)) < (YEAR(CURRENT_DATE)*100 + MONTH(CURRENT_DATE))
    GROUP BY 1,2,3,4,5,6
)
SELECT
    'AWS' AS cloud,
    year,
    month,
    region,
    arch,
    family,
    CAST(SUM(inst_vcpu_hours) AS DOUBLE) AS vcpu_hours,
    CAST(SUM(inst_vcpus) AS INTEGER) AS vcpus
FROM per_instance
GROUP BY year, month, region, arch, family
ORDER BY year, month, region, arch"

echo "Running Athena query..."
EXECUTION_ID=$(aws athena start-query-execution \
    --query-string "$QUERY" \
    --work-group "primary" \
    --query-execution-context "Database=${DATABASE_NAME},Catalog=AwsDataCatalog" \
    --result-configuration "OutputLocation=${S3_OUTPUT}" \
    --region "$REGION" \
    --output text)
echo "Query execution ID: $EXECUTION_ID"

while true; do
    STATUS=$(aws athena get-query-execution --query-execution-id "$EXECUTION_ID" --region "$REGION" \
        --query 'QueryExecution.Status.State' --output text)
    echo "Query status: $STATUS"
    if [ "$STATUS" = "SUCCEEDED" ]; then
        break
    elif [ "$STATUS" = "FAILED" ] || [ "$STATUS" = "CANCELLED" ]; then
        REASON=$(aws athena get-query-execution --query-execution-id "$EXECUTION_ID" --region "$REGION" \
            --query 'QueryExecution.Status.StateChangeReason' --output text)
        echo "Query failed: $REASON"
        exit 1
    fi
    sleep 5
done

RESULTS_LOCATION=$(aws athena get-query-execution --query-execution-id "$EXECUTION_ID" --region "$REGION" \
    --query 'QueryExecution.ResultConfiguration.OutputLocation' --output text)

echo "Clean up: deleting crawler..."
aws glue delete-crawler --name "$CRAWLER_NAME" --region "$REGION" 2>/dev/null || true

aws s3 cp "$RESULTS_LOCATION" "$LONG_CSV" --region "$REGION"
echo "Normalized data written to: $LONG_CSV"

# ---- Build the Excel report (optional) --------------------------------------
if command -v python3 >/dev/null 2>&1; then
    echo "Building Excel report..."
    python3 ../build_report.py "$LONG_CSV" -o "$REPORT_XLSX" || {
        echo "Report build failed (is openpyxl installed? 'pip install --user openpyxl')."
        echo "The normalized CSV is still available at $LONG_CSV."
    }
else
    echo "python3 not found - skipping Excel build."
    echo "Run it later with:  python3 ../build_report.py $LONG_CSV -o $REPORT_XLSX"
fi

echo ""
echo "Done."
head -n 10 "$LONG_CSV"
