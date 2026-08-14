# CCA Export

Scripts and queries that extract your running compute inventory from **AWS, Azure, and GCP** and format it for the **Cloud Cost Assessment (CCA) Portfolio Template** (`AWS_AZURE_GCP.xlsx`) — so you can paste the rows straight in or upload the CSV to the CCA portal.

Each cloud has its own folder with a script, a standalone query, and a detailed README. This page is the overview; pick your cloud below.

## Pick your cloud

Every cloud has **two paths**: a recommended path that uses **real billing data**, and an **estimated fallback** for when you don't have billing access.

| Cloud | Folder | ✅ Recommended (real billing data) | Fallback (estimated) |
|-------|--------|-----------------------------------|----------------------|
| **AWS** | [`aws/`](aws/) | Cost & Usage Report (CUR) via Glue + Athena — **real metered hours** | Cost Explorer / AWS Config — inventory, hours estimated |
| **Azure** | [`azure/`](azure/) | Cost Management billing export — **real metered hours** | Resource Graph snapshot — hours estimated (`count × 730`) |
| **GCP** | [`gcp/`](gcp/) | BigQuery billing export — **real set of instances** that ran during the month | Cloud Asset Inventory snapshot — hours estimated (`count × 730`) |

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

**Always prefer the billing path when you can get access to it** — it reports the real set of instances that ran during the month, not a guess.

- **AWS** — billing (CUR) gives true metered hours.
- **Azure** — billing (Cost Management export) gives true metered hours.
- **GCP** — billing (BigQuery export) sees the real set of instances that ran, but hours are still `count × 730`, because GCP bills per vCPU/GB rather than per instance-hour.

Use the **estimated fallback** (Resource Graph / Cloud Asset Inventory / Cost Explorer) only when billing access isn't available. A fallback is a **point-in-time snapshot**: it counts only the VMs that exist at the instant you run it, assumes each ran 24/7 (`count × 730`), and misses anything created or deleted mid-month.

## Which path to use

1. **Fastest, no install** — each README has a *"Get this data from the portal (no CLI)"* section (Athena / Resource Graph Explorer / BigQuery Studio).
2. **Cloud Shell** — upload the script into AWS/Azure/GCP Cloud Shell; the CLI and auth are already there.
3. **Local** — install the cloud CLI (+ `jq` for Azure/GCP), configure the variables at the top of the script, and run it.
