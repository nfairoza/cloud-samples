#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Proof of Performance - GCP export (BigQuery billing export)
# =============================================================================
# Reads 12 months of Compute Engine vCPU (Core) usage from your BigQuery billing
# export, classifies each machine family as Intel / AMD / ARM, and writes the
# normalized CSV consumed by ../build_report.py:
#
#   cloud,year,month,region,arch,family,vcpu_hours
#
# WHY THIS WORKS: GCP prices compute per vCPU ("Core") and per GB RAM. The Core
# SKU's usage (amount_in_pricing_units) is already in vCPU-hours, so summing the
# Core SKUs gives vcpu_hours directly - no machine-size lookup needed.
#
# Requires a "Detailed usage cost" billing export to BigQuery.
# =============================================================================

# ------------------------- Configuration (EDIT ME) ---------------------------
PROJECT_ID="your-gcp-project-id"
DATASET_NAME="billing_data"
# The detailed export table, e.g. gcp_billing_export_resource_v1_XXXXXX_XXXXXX_XXXXXX
BILLING_TABLE="gcp_billing_export_resource_v1_XXXXXX_XXXXXX_XXXXXX"
LONG_CSV="./gcp_pop_long.csv"
REPORT_XLSX="./pop_report.xlsx"
# -----------------------------------------------------------------------------

echo "========================================="
echo " Proof of Performance - GCP export"
echo "========================================="

command -v bq >/dev/null 2>&1 || { echo "ERROR: 'bq' (Google Cloud SDK) not installed."; exit 1; }
gcloud config set project "$PROJECT_ID" >/dev/null

if ! bq show --format=none "$PROJECT_ID:$DATASET_NAME.$BILLING_TABLE" >/dev/null 2>&1; then
    echo "ERROR: billing table $DATASET_NAME.$BILLING_TABLE not found."
    echo "List tables:  bq ls $PROJECT_ID:$DATASET_NAME"
    echo "Set up export: https://cloud.google.com/billing/docs/how-to/export-data-bigquery-setup"
    exit 1
fi

SQL="
SELECT
  'GCP' AS cloud,
  EXTRACT(YEAR FROM usage_start_time) AS year,
  EXTRACT(MONTH FROM usage_start_time) AS month,
  IFNULL(location.region, 'unknown') AS region,
  CASE
    WHEN REGEXP_CONTAINS(LOWER(sku.description), r'\barm\b')
      OR REGEXP_CONTAINS(LOWER(sku.description), r'\b(t2a|c4a)\b') THEN 'ARM'
    WHEN REGEXP_CONTAINS(LOWER(sku.description), r'\bamd\b')
      OR REGEXP_CONTAINS(LOWER(sku.description), r'\b(n2d|c2d|t2d|c3d)\b') THEN 'AMD'
    ELSE 'Intel'
  END AS arch,
  IFNULL(REGEXP_EXTRACT(sku.description, r'([A-Za-z][0-9]+[A-Za-z]?)'), 'other') AS family,
  CAST(SUM(usage.amount_in_pricing_units) AS FLOAT64) AS vcpu_hours
FROM \`${PROJECT_ID}.${DATASET_NAME}.${BILLING_TABLE}\`
WHERE service.description = 'Compute Engine'
  AND LOWER(sku.description) LIKE '%core%'
  AND DATE(usage_start_time) >= DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 12 MONTH), MONTH)
  AND DATE(usage_start_time) <  DATE_TRUNC(CURRENT_DATE(), MONTH)
GROUP BY year, month, region, arch, family
ORDER BY year, month, region, arch, family
"

echo "Running BigQuery query (last 12 completed months)..."
# --format=csv prints exactly: cloud,year,month,region,arch,family,vcpu_hours
bq query --use_legacy_sql=false --format=csv --quiet "$SQL" > "$LONG_CSV"
echo "Normalized data written to: $LONG_CSV"

if command -v python3 >/dev/null 2>&1; then
    echo "Building Excel report..."
    python3 ../build_report.py "$LONG_CSV" -o "$REPORT_XLSX" || {
        echo "Report build failed (try: pip install --user openpyxl)."
        echo "The normalized CSV is still available at $LONG_CSV."
    }
else
    echo "python3 not found - run later:  python3 ../build_report.py $LONG_CSV -o $REPORT_XLSX"
fi

echo ""
echo "Done."
head -n 10 "$LONG_CSV"
