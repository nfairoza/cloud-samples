#!/bin/bash
set -e

# Configuration
PROJECT_ID="your-gcp-project-id"
DATASET_NAME="billing_data"
BILLING_TABLE="gcp_billing_export"
OUTPUT_BUCKET="gs://noortestdata/query_results/"
REGION="us-east1"

# Ensure gcloud is configured correctly
echo "Verifying gcloud configuration..."
gcloud config set project $PROJECT_ID

# Check if the billing export dataset exists
if ! bq ls --dataset "$PROJECT_ID:$DATASET_NAME" &>/dev/null; then
    echo "Dataset $DATASET_NAME does not exist. Please ensure billing export to BigQuery is set up."
    echo "Visit: https://cloud.google.com/billing/docs/how-to/export-data-bigquery-setup"
    exit 1
fi

# Check if the billing table exists
if ! bq ls --format=sparse "$PROJECT_ID:$DATASET_NAME.$BILLING_TABLE" &>/dev/null; then
    echo "Billing export table $BILLING_TABLE not found in dataset $DATASET_NAME."
    echo "Please verify your billing export configuration."
    exit 1
fi

echo "Running BigQuery query..."

# Create a temporary file for the query
QUERY_FILE=$(mktemp)
cat << EOF > "$QUERY_FILE"
SELECT
  'GCP' as Cloud,
  REGEXP_EXTRACT(location.region, r'[a-z]+-[a-z]+[0-9]') as Region,
  machine_type as Size,
  COUNT(DISTINCT resource.name) as Quantity,
  CAST(SUM(usage.amount) as INT64) as "Total number of hours per month",
  CASE
    WHEN LOWER(pricing.pricing_type) LIKE '%commit%' THEN 'Reserved'
    WHEN LOWER(pricing.pricing_type) LIKE '%spot%' THEN 'Spot'
    WHEN LOWER(pricing.pricing_type) LIKE '%on demand%' THEN 'On-Demand'
    ELSE 'not supported'
  END as "Pricing Model"
FROM
  \`$PROJECT_ID.$DATASET_NAME.$BILLING_TABLE\`
WHERE
  service.description = 'Compute Engine'
  AND sku.description LIKE '%Instance%'
  AND usage.unit = 'hour'
GROUP BY
  Region,
  Size,
  "Pricing Model"
ORDER BY
  Size,
  Region,
  "Pricing Model"
EOF

# Execute the query and save results to GCS
TIMESTAMP=$(date +%Y%m%d%H%M%S)
OUTPUT_FILE="${OUTPUT_BUCKET}gcp_results_${TIMESTAMP}.csv"

echo "Executing query and exporting results to $OUTPUT_FILE"
bq query \
  --use_legacy_sql=false \
  --format=csv \
  --destination_table="${PROJECT_ID}:${DATASET_NAME}.temp_export_${TIMESTAMP}" \
  --dataset_id="${PROJECT_ID}:${DATASET_NAME}" \
  --replace=true \
  < "$QUERY_FILE"

# Export the results to GCS
bq extract \
  --destination_format=CSV \
  --field_delimiter="," \
  --print_header=true \
  "${PROJECT_ID}:${DATASET_NAME}.temp_export_${TIMESTAMP}" \
  "$OUTPUT_FILE"

# Download the CSV file locally
LOCAL_FILE="./gcp_results.csv"
gsutil cp "$OUTPUT_FILE" "$LOCAL_FILE"

# Clean up temporary resources
echo "Cleaning up temporary resources..."
bq rm -f "${PROJECT_ID}:${DATASET_NAME}.temp_export_${TIMESTAMP}"
rm "$QUERY_FILE"

echo "Results downloaded to $LOCAL_FILE"
echo "Complete! GCP compute instance data has been extracted in the required format."
