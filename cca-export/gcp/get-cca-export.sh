#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# GCP CCA Export - BigQuery billing export approach (ADVANCED)
# =============================================================================
# Produces a CSV that matches the CCA Portfolio Template columns:
#
#   Cloud, Region, Size, Quantity, Total number of hours per month, Pricing Model
#
# Use this only if you already have "Detailed usage cost" billing export to
# BigQuery configured. It reads real billing data so it can see Spot vs
# On-Demand accurately and spans the whole project's usage last month.
#
# If you do NOT have billing export set up, use get-cca-export-asset-730.sh
# instead (no setup required).
# =============================================================================

# ------------------------- Configuration (EDIT ME) ---------------------------
PROJECT_ID="your-gcp-project-id"     # project that owns the billing dataset
DATASET_NAME="billing_data"          # BigQuery dataset holding the export
# Table name of the DETAILED usage export, e.g.:
#   gcp_billing_export_resource_v1_XXXXXX_XXXXXX_XXXXXX
BILLING_TABLE="gcp_billing_export_resource_v1_XXXXXX_XXXXXX_XXXXXX"
HOURS_PER_MONTH=730                  # full-month runtime estimate per VM
OUTPUT_FILE="./gcp_results.csv"
# -----------------------------------------------------------------------------

echo "========================================="
echo " GCP CCA Export (BigQuery billing)"
echo "========================================="

# ---- 1. Dependency checks ----------------------------------------------------
for tool in gcloud bq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: '$tool' is not installed (part of the Google Cloud SDK)."
        exit 1
    fi
done

gcloud config set project "$PROJECT_ID" >/dev/null

# ---- 2. Verify the billing dataset/table exist ------------------------------
if ! bq ls --dataset "$PROJECT_ID:$DATASET_NAME" >/dev/null 2>&1; then
    echo "ERROR: Dataset '$DATASET_NAME' not found."
    echo "Set up billing export to BigQuery first:"
    echo "  https://cloud.google.com/billing/docs/how-to/export-data-bigquery-setup"
    exit 1
fi
if ! bq show --format=none "$PROJECT_ID:$DATASET_NAME.$BILLING_TABLE" >/dev/null 2>&1; then
    echo "ERROR: Table '$BILLING_TABLE' not found in dataset '$DATASET_NAME'."
    echo "List available tables with:  bq ls $PROJECT_ID:$DATASET_NAME"
    exit 1
fi

# ---- 3. Build and run the query ---------------------------------------------
# NOTES:
# * "Size" comes from the system_labels 'compute.googleapis.com/machine_spec'
#   entry, which is only present in the DETAILED (resource-level) export.
# * "Total number of hours per month" is count x HOURS_PER_MONTH. GCP bills per
#   vCPU/GB rather than per instance-hour, so a true instance-hour figure is not
#   directly available; the estimate keeps parity with the CCA template.
# * Pricing detects Spot/Preemptible from the SKU description. Committed Use
#   Discounts (Reserved) are applied as credits and are hard to attribute per
#   instance, so they are reported as On-Demand here.
SQL="
WITH vms AS (
  SELECT
    location.region AS region,
    (SELECT value FROM UNNEST(system_labels)
       WHERE key = 'compute.googleapis.com/machine_spec') AS size,
    resource.name AS resource_name,
    CASE
      WHEN LOWER(sku.description) LIKE '%spot%'
        OR LOWER(sku.description) LIKE '%preemptible%' THEN 'Spot'
      ELSE 'On-Demand'
    END AS pricing_model
  FROM \`${PROJECT_ID}.${DATASET_NAME}.${BILLING_TABLE}\`
  WHERE service.description = 'Compute Engine'
    AND DATE(usage_start_time) >= DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH)
    AND DATE(usage_start_time) <  DATE_TRUNC(CURRENT_DATE(), MONTH)
    AND (SELECT value FROM UNNEST(system_labels)
           WHERE key = 'compute.googleapis.com/machine_spec') IS NOT NULL
)
SELECT
  region,
  size,
  COUNT(DISTINCT resource_name) AS quantity,
  COUNT(DISTINCT resource_name) * ${HOURS_PER_MONTH} AS hours,
  pricing_model
FROM vms
GROUP BY region, size, pricing_model
ORDER BY size, region, pricing_model
"

echo "Running BigQuery query (last full calendar month)..."
# --format=csv prints a header row (region,size,quantity,hours,pricing_model);
# we drop it and write the CCA template header instead.
QUERY_CSV=$(bq query --use_legacy_sql=false --format=csv --quiet "$SQL")

echo "Cloud,Region,Size,Quantity,Total number of hours per month,Pricing Model" > "$OUTPUT_FILE"
echo "$QUERY_CSV" | tail -n +2 | while IFS= read -r line; do
    [ -z "$line" ] && continue
    echo "GCP,$line"
done >> "$OUTPUT_FILE"

ROWS=$(($(wc -l < "$OUTPUT_FILE") - 1))
echo ""
echo "Done. Wrote $ROWS data row(s) to: $OUTPUT_FILE"
echo ""
echo "Preview:"
echo "----------------------------------------"
head -n 10 "$OUTPUT_FILE"
