#!/bin/bash
set -e

# Configuration
PROJECT_ID="amdsales-fae-fieldsupport"  # Update with your project ID
OUTPUT_FILE="./gcp_cca_export.csv"
TEMP_FILE="/tmp/gcp_instances_raw.json"
CURRENT_MONTH=$(date +"%Y-%m")
DAYS_IN_MONTH=$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%d)

echo "GCP CCA Export Script"
echo "===================="

# Ensure gcloud is configured correctly
echo "Verifying gcloud configuration..."
gcloud config set project $PROJECT_ID

# Check if the Cloud Asset API is enabled
if ! gcloud services list --enabled | grep -q "cloudasset.googleapis.com"; then
    echo "Cloud Asset API is not enabled. Enabling now..."
    gcloud services enable cloudasset.googleapis.com
fi

echo "Fetching compute instance inventory data..."

# Use Cloud Asset Inventory to export instance data
gcloud asset list \
    --project=$PROJECT_ID \
    --content-type=resource \
    --asset-types=compute.googleapis.com/Instance \
    --format=json > $TEMP_FILE

# Check if any instances were found
INSTANCE_COUNT=$(jq length $TEMP_FILE)
if [ "$INSTANCE_COUNT" -eq 0 ]; then
    echo "No compute instances found in project $PROJECT_ID"
    exit 0
fi

echo "Found $INSTANCE_COUNT compute instances."

# Get current date for calculating instance uptime
CURRENT_DATE=$(date +"%Y-%m-%dT%H:%M:%S")

# Create CSV header matching the template
echo "Cloud,Region,Size,Quantity,Total number of hours per month,Pricing Model" > $OUTPUT_FILE

# Process and estimate hours
echo "Processing data and estimating usage hours..."

# Estimate hours based on instance creation time and status
jq -r '.[] |
    (.resource.data.zone | split("/") | .[-1] | capture("(?<region>[a-z]+-[a-z]+[0-9])")) as $region |
    (.resource.data.machineType | split("/") | .[-1]) as $machineType |
    (.resource.data.status) as $status |
    (.resource.data.creationTimestamp) as $created |
    {
        region: $region,
        machineType: $machineType,
        status: $status,
        created: $created
    }
' $TEMP_FILE > /tmp/processed_instances.json

# Group by region, machine type and estimate pricing model from instance properties
jq -r -s '
    # Group by region and machine type
    group_by(.region, .machineType) |
    map(
        {
            region: .[0].region,
            machineType: .[0].machineType,
            count: length,
            # Estimate hours - in reality this needs more complex logic
            hours: length * 730, # Approximation: 730 hours in a month
            # Try to guess pricing model from instance name or properties
            # Without billing data, this is a best guess
            pricingModel: "On-Demand" # Default to On-Demand for all
        }
    ) |
    .[] |
    "GCP,\(.region),\(.machineType),\(.count),\(.hours),\(.pricingModel)"
' /tmp/processed_instances.json >> $OUTPUT_FILE

echo "Cleaning up temporary files..."
rm $TEMP_FILE
rm /tmp/processed_instances.json

echo "Complete! GCP CCA data has been exported to: $OUTPUT_FILE"
echo ""
echo "NOTE: Without billing data access, the following approximations were made:"
echo "- Total hours per month: Assumed full month usage (730 hours) for all running instances"
echo "- Pricing Model: Defaulted to 'On-Demand' since actual commitment info is not available"
echo ""
echo "To get precise billing information, consider setting up Billing Export to BigQuery"

# Display preview of the output
echo -e "\nPreview of generated CCA export:"
echo "----------------------------------------"
head -n 10 $OUTPUT_FILE
