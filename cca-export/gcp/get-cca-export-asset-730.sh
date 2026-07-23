#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# GCP CCA Export - Cloud Asset Inventory (inventory) approach
# =============================================================================
# Produces a CSV that matches the CCA Portfolio Template columns:
#
#   Cloud, Region, Size, Quantity, Total number of hours per month, Pricing Model
#
# This is the RECOMMENDED script to start with: it needs no BigQuery billing
# export and returns exact instance counts, machine types, regions and
# Spot/Standard status straight from Cloud Asset Inventory.
#
# "Total number of hours per month" is estimated as (instance count x
# HOURS_PER_MONTH) because inventory does not expose actual metered hours.
# For billing-accurate data use get-cca-export.sh (BigQuery).
# =============================================================================

# ------------------------- Configuration (EDIT ME) ---------------------------
PROJECT_ID="your-gcp-project-id"        # gcloud project to scan
HOURS_PER_MONTH=730                      # full-month runtime estimate per VM
RUNNING_ONLY="false"                     # "true" = only count RUNNING instances
OUTPUT_FILE="./gcp_cca_export.csv"
# -----------------------------------------------------------------------------

echo "========================================="
echo " GCP CCA Export (Cloud Asset Inventory)"
echo "========================================="

# ---- 1. Dependency checks ----------------------------------------------------
for tool in gcloud jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: '$tool' is not installed. See README.md > Prerequisites."
        exit 1
    fi
done

# ---- 2. Auth check -----------------------------------------------------------
if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q .; then
    echo "ERROR: No active gcloud account. Run:  gcloud auth login"
    exit 1
fi

echo "Setting project to: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" >/dev/null

# ---- 3. Ensure the Cloud Asset API is enabled -------------------------------
if ! gcloud services list --enabled --format='value(config.name)' | grep -q "cloudasset.googleapis.com"; then
    echo "Enabling Cloud Asset API (cloudasset.googleapis.com)..."
    gcloud services enable cloudasset.googleapis.com
fi

# ---- 4. Pull the compute instance inventory ---------------------------------
echo "Fetching compute instance inventory..."
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

gcloud asset list \
    --project="$PROJECT_ID" \
    --content-type=resource \
    --asset-types=compute.googleapis.com/Instance \
    --format=json > "$TMP"

INSTANCE_COUNT=$(jq 'length' "$TMP")
echo "Found $INSTANCE_COUNT compute instance(s)."
if [ "$INSTANCE_COUNT" -eq 0 ]; then
    echo "No instances found in project $PROJECT_ID. Nothing to export."
    exit 0
fi

# ---- 5. Group by region/size/pricing and write CSV --------------------------
echo "Cloud,Region,Size,Quantity,Total number of hours per month,Pricing Model" > "$OUTPUT_FILE"

jq -r --argjson hpm "$HOURS_PER_MONTH" --arg running "$RUNNING_ONLY" '
    [ .[]
      | .resource.data as $d
      | {
          # zone URL ".../zones/us-central1-a" -> region "us-central1"
          region:  ($d.zone | split("/") | last
                     | capture("(?<r>[a-z]+-[a-z]+[0-9]+)").r),
          # machineType URL ".../machineTypes/n2-standard-4" -> "n2-standard-4"
          size:    ($d.machineType | split("/") | last),
          status:  ($d.status // "UNKNOWN"),
          pricing: ( if (($d.scheduling.provisioningModel // "") == "SPOT")
                        or (($d.scheduling.preemptible // false) == true)
                     then "Spot" else "On-Demand" end )
        }
      | select( $running != "true" or .status == "RUNNING" )
    ]
    | group_by([.region, .size, .pricing])
    | .[]
    | "GCP,\(.[0].region),\(.[0].size),\(length),\(length * ($hpm|tonumber)),\(.[0].pricing)"
' "$TMP" >> "$OUTPUT_FILE"

ROWS=$(($(wc -l < "$OUTPUT_FILE") - 1))
echo ""
echo "Done. Wrote $ROWS data row(s) to: $OUTPUT_FILE"
echo ""
echo "Preview:"
echo "----------------------------------------"
head -n 10 "$OUTPUT_FILE"
echo ""
echo "NOTE: 'Total number of hours per month' = instance count x $HOURS_PER_MONTH (estimate)."
echo "      Committed Use Discounts (Reserved) cannot be detected from inventory;"
echo "      those instances appear as 'On-Demand'. Spot instances ARE detected."
