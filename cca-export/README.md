# CCA Export

Scripts and queries that extract your running compute inventory from **AWS, Azure, and GCP** and format it for the **Cloud Cost Assessment (CCA) Portfolio Template** (`AWS_AZURE_GCP.xlsx`) — so you can paste the rows straight in or upload the CSV to the CCA portal.

Each cloud has its own folder with a script, a standalone query, and a detailed README. This page is the overview; pick your cloud below.

## Pick your cloud

| Cloud | Folder | Data source | Real hours? |
|-------|--------|-------------|-------------|
| **AWS** | [`aws/`](aws/) | Cost & Usage Report (CUR) via Glue + Athena | ✅ Real metered hours |
| **Azure** | [`azure/`](azure/) | Resource Graph inventory (billing export optional) | ⚠️ Estimated (`count × 730`) by default |
| **GCP** | [`gcp/`](gcp/) | BigQuery billing export, or Cloud Asset Inventory | Billing sees the real instance set; hours are `count × 730` |

> Each folder's README covers prerequisites, configuration, a no-CLI portal path, and a Cloud Shell path. Start there for step-by-step instructions.

## What every script produces

All three clouds emit a CSV with the **same CCA template columns**, so the output drops into one spreadsheet regardless of cloud:

| Cloud | Region | Size | Quantity | Total number of hours per month | Pricing Model |
|-------|--------|------|----------|---------------------------------|---------------|
| AWS | us-east-1 | m7a.xlarge | 5 | 3600 | On-Demand |
| Azure | eastus | Standard_D2s_v3 | 4 | 2920 | On-Demand |
| GCP | us-central1 | n2-standard-4 | 3 | 2190 | Spot |

- **Region / Size** use each cloud's native short codes, matching the Region dropdown in Sheet2 of the template.
- **Quantity** is the number of instances of that size/region/pricing.
- **Pricing Model** is `On-Demand`, `Spot`, or (AWS only) `Reserved`.
- The template's optional leading `UUID` column is not produced — leave it blank on upload.

## A note on accuracy

Only **AWS CUR** gives true metered hours. Azure and GCP hours are estimated as `count × 730` (a full month at 24/7), because their inventory APIs don't report runtime and they bill per vCPU/GB rather than per instance-hour. Where a **real billing export** is available (Azure Cost Management, GCP BigQuery), the per-cloud README explains how to use it for the accurate set of instances — always prefer billing data over an inventory snapshot when you can get it.

## Which path to use

1. **Fastest, no install** — each README has a *"Get this data from the portal (no CLI)"* section (Athena / Resource Graph Explorer / BigQuery Studio).
2. **Cloud Shell** — upload the script into AWS/Azure/GCP Cloud Shell; the CLI and auth are already there.
3. **Local** — install the cloud CLI (+ `jq` for Azure/GCP), configure the variables at the top of the script, and run it.
