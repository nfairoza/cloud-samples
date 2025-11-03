# AWS CUR Export Script for Cloud Cost Assessment

This script automates the extraction and analysis of AWS Cost and Usage Report (CUR) data for Cloud Cost Assessment (CCA) template requirements for cost advice.

## Overview

Two versions are available depending on your CUR configuration:

- **CUR 2.0 (Data Exports)**: Uses modern Parquet format with Resource IDs
- **Legacy CUR**: Uses traditional Athena-based CUR tables

## Version Comparison

| Feature | Legacy CUR | CUR 2.0 (Data Exports) |
|---------|------------|------------------------|
| Format | CSV/Gzip files | Parquet files |
| Resource IDs | Optional | Included by default |
| Script | `get-cca-export-cur-legacy.sh` | `get-cca-export.sh` |
| Query File | `cca-cur-query-legacy.sql` | `cca-cur-query.sql` |
| Approach | Glue Crawler + Athena | Glue Crawler + Athena |

## Prerequisites

- AWS CLI installed and configured
- Appropriate AWS IAM permissions for S3, Glue, and Athena
- Active CUR configured in your AWS account
- Data stored in S3 bucket

### For CUR 2.0:
- CUR 2.0 data exports with resource IDs enabled
- Data in Parquet format

### For Legacy CUR:
- Legacy CUR reports configured
- Data in CSV/Gzip format

## Configuration

Update these variables in the script according to your environment:

### CUR Script Configuration for both CUR 2.0 and Legacy CUR
```bash
REGION="us-east-2"                        # AWS region
DATABASE_NAME="cur_reports"               # Glue database name OPTIONAL
CRAWLER_NAME="cur_crawler"                # Glue crawler name OPTIONAL
S3_PATH="s3://your-bucket-name/your-cur-prefix/data/"  # Source CUR data path
S3_OUTPUT="s3://your-bucket-name/query_results/"       # Query results output path
ROLE_NAME="AWSGlueServiceRole-crawler"    # IAM role name OPTIONAL
```


## Usage

### Option 1: CUR 2.0 (Recommended for new deployments)

1. Download the script:
```bash
wget https://raw.githubusercontent.com/nfairoza/cloud-samples/refs/heads/main/cca-export/aws/get-cca-export.sh
```

2. Make the script executable:
```bash
chmod +x get-cca-export.sh
```

3. Run the script:
```bash
./get-cca-export.sh
```

### Option 2: Legacy CUR

1. Download the legacy script:
```bash
wget https://raw.githubusercontent.com/nfairoza/cloud-samples/refs/heads/main/cca-export/aws/get-cca-export-cur-legacy.sh
```

2. Make the script executable:
```bash
chmod +x get-cca-export-cur-legacy.sh
```

3. Run the script:
```bash
./get-cca-export-cur-legacy.sh
```

## Output

Both scripts generate a CSV file containing:
- Usage hours calculated from `line_item_usage_amount`
- Instance counts based on unique resource IDs (CUR 2.0) or usage patterns (Legacy)
- Usage hours aggregated by SKU
- Data formatted for CCA Portfolio Template upload

## Notes

- **Both scripts** use Glue crawler to catalog data, then query with Athena
- **CUR 2.0**: Works with Parquet format data from Data Exports
- **Legacy CUR**: Works with CSV/Gzip format from traditional CUR reports
- Both scripts download results locally and clean up intermediate files
- Ensure your IAM role has necessary permissions for S3, Athena, and Glue

## Choosing the Right Version

**Use CUR 2.0** if:
- You're setting up CUR for the first time
- You need resource-level tracking
- You want faster query performance with Parquet format

**Use Legacy CUR** if:
- You have existing CUR configured with Athena
- You're not ready to migrate to CUR 2.0
- Your organization has standardized on legacy CUR

## Additional Resources

- [AWS Cost and Usage Reports Documentation](https://docs.aws.amazon.com/cur/latest/userguide/)
- [CUR 2.0 Migration Guide](https://docs.aws.amazon.com/cur/latest/userguide/cur-data-exports.html)

## Support Files

- `cca-cur-query.sql` - Athena query for CUR 2.0
- `cca-cur-query-legacy.sql` - Athena query for Legacy CUR
- `cur-setup.xlsx` - Configuration reference spreadsheet
