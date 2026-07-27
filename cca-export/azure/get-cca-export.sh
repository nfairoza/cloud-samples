#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Azure CCA Export - Resource Graph (inventory SNAPSHOT) approach
# =============================================================================
# Produces a CSV that matches the CCA Portfolio Template columns:
#
#   Cloud, Region, Size, Quantity, Total number of hours per month, Pricing Model
#
# ESTIMATE / FALLBACK. This reads Azure Resource Graph, which is a POINT-IN-TIME
# SNAPSHOT of the VMs that exist right now - not the month's actual usage. VM
# counts, sizes, regions and Spot/On-Demand are exact for this instant, but:
#   * VMs created or deleted mid-month are mis-counted or missed entirely, and
#   * "Total number of hours per month" = VM count x HOURS_PER_MONTH is a GUESS
#     (assumes every VM ran 24/7). Inventory does not expose metered hours.
#
# RECOMMENDED for real data: use a Cost Management billing export (real metered
# hours + the instances that actually ran during the month). See the "Advanced:
# billing-accurate hours" section of README.md. Use this snapshot script only as
# a quick, no-setup fallback when you don't have billing/export access.
# =============================================================================

# ------------------------- Configuration (EDIT ME) ---------------------------
# Leave SUBSCRIPTION_ID empty ("") to query EVERY subscription you have access
# to. Set it to a specific subscription GUID to limit the scope.
SUBSCRIPTION_ID=""

# Hours used to approximate a full month of runtime (24 x 365 / 12 = 730).
HOURS_PER_MONTH=730

# "true"  = only count VMs that are currently powered on (running)
# "false" = count every VM regardless of power state (safest for a first test)
RUNNING_ONLY="false"

# Where the CSV is written.
OUTPUT_FILE="./azure_cca_export.csv"
# -----------------------------------------------------------------------------

echo "========================================="
echo " Azure CCA Export (Resource Graph)"
echo "========================================="

# ---- 1. Dependency checks ----------------------------------------------------
if ! command -v az >/dev/null 2>&1; then
    echo "ERROR: Azure CLI ('az') is not installed. See README.md > Prerequisites."
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: 'jq' is not installed. Install it and re-run (see README.md)."
    exit 1
fi

# ---- 2. Make sure we are logged in ------------------------------------------
if ! az account show >/dev/null 2>&1; then
    echo "ERROR: You are not logged in to Azure. Run:  az login"
    exit 1
fi

# ---- 3. Ensure the Resource Graph extension is present ----------------------
if ! az extension show --name resource-graph >/dev/null 2>&1; then
    echo "Installing the 'resource-graph' CLI extension..."
    az extension add --name resource-graph
fi

# ---- 4. Build the query scope -----------------------------------------------
SCOPE_ARGS=()
if [ -n "$SUBSCRIPTION_ID" ]; then
    SCOPE_ARGS=(--subscriptions "$SUBSCRIPTION_ID")
    echo "Scope: subscription $SUBSCRIPTION_ID"
else
    echo "Scope: ALL accessible subscriptions"
fi

# ---- 5. Optional power-state filter -----------------------------------------
POWER_FILTER=""
if [ "$RUNNING_ONLY" = "true" ]; then
    POWER_FILTER="| where powerState =~ 'PowerState/running'"
fi

# ---- 6. Resource Graph (KQL) query ------------------------------------------
# Standalone VMs only. VM Scale Set instances are NOT included (see README).
KQL="Resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend size = tostring(properties.hardwareProfile.vmSize)
| extend priority = tostring(properties.priority)
| extend powerState = tostring(properties.extended.instanceView.powerState.code)
| extend pricing = iff(priority =~ 'Spot', 'Spot', 'On-Demand')
${POWER_FILTER}
| summarize Quantity = count() by location, size, pricing
| project Region = location, Size = size, Quantity, pricing
| order by Size asc, Region asc"

echo "Running Resource Graph query..."
RESULT=$(az graph query -q "$KQL" "${SCOPE_ARGS[@]}" --first 1000 -o json)

TOTAL_RECORDS=$(echo "$RESULT" | jq -r '.totalRecords // 0')
if [ "$TOTAL_RECORDS" -gt 1000 ]; then
    echo "WARNING: $TOTAL_RECORDS grouped rows found; only the first 1000 were"
    echo "         returned. See README.md > Troubleshooting for paging."
fi

# ---- 7. Write CSV in the exact CCA template column order ---------------------
echo "Cloud,Region,Size,Quantity,Total number of hours per month,Pricing Model" > "$OUTPUT_FILE"
echo "$RESULT" | jq -r --argjson hpm "$HOURS_PER_MONTH" '
    .data[]
    | [ "Azure", .Region, .Size, .Quantity, (.Quantity * $hpm), .pricing ]
    | @csv
' >> "$OUTPUT_FILE"

ROWS=$(($(wc -l < "$OUTPUT_FILE") - 1))
echo ""
echo "Done. Wrote $ROWS data row(s) to: $OUTPUT_FILE"
echo ""
echo "Preview:"
echo "----------------------------------------"
head -n 10 "$OUTPUT_FILE"
echo ""
echo "============================== READ THIS =============================="
echo "ESTIMATE ONLY - this is a POINT-IN-TIME SNAPSHOT, not the month's usage."
echo "  * Counts only VMs that exist RIGHT NOW. VMs created or deleted earlier"
echo "    this month are mis-counted or missed entirely."
echo "  * 'Total number of hours per month' = VM count x $HOURS_PER_MONTH assumes every"
echo "    VM ran 24/7 all month. It is a guess, not measured data."
echo "  * Reserved Instances appear as 'On-Demand'; Spot IS detected."
echo ""
echo "  For REAL data (actual metered hours + instances that ran during the"
echo "  month), set up a Cost Management billing export - see README.md"
echo "  ('Advanced: billing-accurate hours'). Billing is the recommended path."
echo "======================================================================"
