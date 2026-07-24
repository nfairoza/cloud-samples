#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Proof of Performance - GCP export (BigQuery billing export)
# =============================================================================
# Reads 12 months of Compute Engine usage from your BigQuery billing export,
# classifies each machine family as Intel / AMD / ARM, and writes the normalized
# CSV consumed by ../build_report.py:
#
#   cloud,year,month,region,arch,family,vcpu_hours,vcpus
#
# vcpu_hours = SUM(Core SKU amount_in_pricing_units) - already in vCPU-hours
#              because GCP prices compute per vCPU ("Core"). (consumption)
# vcpus      = provisioned vCPUs that month = SUM over DISTINCT instances
#              (resource.name) of the vCPU count parsed from the machine type in
#              system_labels 'compute.googleapis.com/machine_spec' (real count).
#
# Requires a "Detailed usage cost" (RESOURCE-level) billing export to BigQuery -
# the machine_spec label is only present in the resource-level export.
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

# Two-level aggregation, all keyed off the machine type in system_labels so
# vcpu_hours and the provisioned vCPU count group consistently:
#   rows         - resource-level Compute Engine rows that carry a machine_spec
#   per_instance - one row per DISTINCT instance/month: its vCPUs (from the type)
#                  and its Core-SKU vCPU-hours
#   final SELECT - sum both up per (month, region, arch, family)
#
# vCPUs are parsed from the machine type name: the integer after standard/highcpu/
# highmem/custom/ultramem/megamem (e.g. n2d-standard-8 -> 8, n2-custom-8-16384 -> 8).
# Shared-core types (e2-micro/small/medium, f1/g1) have no such number and default
# to 2; adjust GCP_SHARED_CORE_VCPUS below if that matters for your fleet.
GCP_SHARED_CORE_VCPUS=2
SQL="
WITH rows AS (
  SELECT
    EXTRACT(YEAR FROM usage_start_time) AS year,
    EXTRACT(MONTH FROM usage_start_time) AS month,
    IFNULL(location.region, 'unknown') AS region,
    resource.name AS resource_name,
    LOWER(sku.description) AS sku_desc,
    usage.amount_in_pricing_units AS amount,
    (SELECT value FROM UNNEST(system_labels)
       WHERE key = 'compute.googleapis.com/machine_spec') AS machine_type
  FROM \`${PROJECT_ID}.${DATASET_NAME}.${BILLING_TABLE}\`
  WHERE service.description = 'Compute Engine'
    AND DATE(usage_start_time) >= DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 12 MONTH), MONTH)
    AND DATE(usage_start_time) <  DATE_TRUNC(CURRENT_DATE(), MONTH)
    AND (SELECT value FROM UNNEST(system_labels)
           WHERE key = 'compute.googleapis.com/machine_spec') IS NOT NULL
),
per_instance AS (
  SELECT
    year, month, region, resource_name,
    REGEXP_EXTRACT(machine_type, r'^([a-z0-9]+)-') AS family,
    CASE
      WHEN REGEXP_CONTAINS(machine_type, r'^(t2a|c4a)') THEN 'ARM'
      WHEN REGEXP_CONTAINS(machine_type, r'^(n2d|c2d|t2d|c3d)') THEN 'AMD'
      ELSE 'Intel'
    END AS arch,
    -- vCPUs from the type; shared-core shapes have no number -> default
    IFNULL(
      CAST(REGEXP_EXTRACT(machine_type,
        r'-(?:standard|highcpu|highmem|custom|ultramem|megamem|hypermem)-(\d+)') AS INT64),
      ${GCP_SHARED_CORE_VCPUS}
    ) AS inst_vcpus,
    SUM(CASE WHEN sku_desc LIKE '%core%' THEN amount ELSE 0 END) AS inst_vcpu_hours
  FROM rows
  GROUP BY year, month, region, resource_name, family, arch, machine_type
)
SELECT
  'GCP' AS cloud,
  year, month, region, arch,
  IFNULL(family, 'other') AS family,
  CAST(SUM(inst_vcpu_hours) AS FLOAT64) AS vcpu_hours,
  SUM(inst_vcpus) AS vcpus
FROM per_instance
GROUP BY year, month, region, arch, family
ORDER BY year, month, region, arch, family
"

echo "Running BigQuery query (last 12 completed months)..."
# --format=csv prints exactly: cloud,year,month,region,arch,family,vcpu_hours,vcpus
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
