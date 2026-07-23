# GCP CCA Export

Extracts your Google Compute Engine instances and formats them for the **Cloud Cost Assessment (CCA) Portfolio Template** so the data can be pasted straight into `AWS_AZURE_GCP.xlsx`.

## Output format

Both scripts write a CSV with exactly these columns (the CCA template columns):

| Cloud | Region | Size | Quantity | Total number of hours per month | Pricing Model |
|-------|--------|------|----------|---------------------------------|---------------|
| GCP | us-central1 | n2-standard-4 | 3 | 2190 | On-Demand |
| GCP | europe-west1 | e2-standard-8 | 1 | 730 | Spot |

- **Region** is emitted in GCP short-code form (`us-central1`, `europe-west1`, ...), which matches the Region dropdown values in `AWS_AZURE_GCP.xlsx` (Sheet2).
- **Size** is the machine type (`n2-standard-4`, `e2-standard-8`, custom types, ...).
- **Quantity** is the number of instances of that machine type/region/pricing.
- **Total number of hours per month** = `Quantity x 730` (a full-month estimate — see [Limitations](#limitations)).
- **Pricing Model** is `Spot` or `On-Demand` (see [Limitations](#limitations) about Committed Use).
- The template's optional leading `UUID` column is **not** produced; leave it blank on upload.

---

## How the data flows

There are two data sources depending on which script you run.

### Option 1 — Cloud Asset Inventory (recommended)

```mermaid
flowchart TD
    A["Cloud Asset Inventory<br/>(live Compute Engine instance metadata)"] --> B["gcloud asset list<br/>--asset-types compute...Instance<br/>--format json"]
    B --> C["jq: derive region (from zone),<br/>size (machine type), Spot/On-Demand"]
    C --> D["jq: group by region/size/pricing,<br/>count instances, hours = count x 730"]
    D --> E["gcp_cca_export.csv"]
    E --> F["Paste rows into<br/>AWS_AZURE_GCP.xlsx"]
```

**Where the data comes from:** **Cloud Asset Inventory** — a live snapshot of the Compute Engine instances in your project. It's an **inventory scan**, not billing data, so hours are estimated.

**What we take in (per instance):**
- `zone` -> Region (`.../zones/us-central1-a` becomes `us-central1`)
- `machineType` -> Size (`n2-standard-4`)
- `scheduling.provisioningModel` / `scheduling.preemptible` -> Spot vs On-Demand
- `status` -> only used if `RUNNING_ONLY="true"`

**How we transform it (in `jq`):** parse each instance, group by region + size + pricing to get **Quantity**, then multiply by `HOURS_PER_MONTH` (730) for **Total number of hours per month**.

### Option 2 — BigQuery billing export (advanced)

```mermaid
flowchart TD
    A["Billing export table in BigQuery<br/>(detailed/resource-level usage cost)"] --> B["bq query (SQL)<br/>filter to Compute Engine,<br/>last full calendar month"]
    B --> C["extract machine type from<br/>system_labels; detect Spot from SKU"]
    C --> D["GROUP BY region/size/pricing,<br/>COUNT(DISTINCT instance)"]
    D --> E["CSV output, prefixed with GCP"]
    E --> F["gcp_results.csv -> AWS_AZURE_GCP.xlsx"]
```

**Where the data comes from:** your **BigQuery billing export** (real billing rows). Used for better Spot detection and cross-project coverage; hours are still estimated as `count x 730` because GCP bills per vCPU/GB, not per instance-hour.

**What we take in:** `location.region`, `system_labels['compute.googleapis.com/machine_spec']` (Size), `resource.name` (counted), `sku.description` (Spot detection), `usage_start_time` (last-month filter), filtered to `service.description = 'Compute Engine'`.

**What comes out (both options):** a CSV in the exact CCA template columns, ready to paste into `AWS_AZURE_GCP.xlsx`.

## Which script should I use?

| Approach | Script | Needs setup? | Accuracy |
|----------|--------|--------------|----------|
| **Cloud Asset Inventory** — recommended | `get-cca-export-asset-730.sh` | None (just `gcloud auth login`) | Exact instance counts/types/regions; hours estimated at 730 |
| **BigQuery billing export** — advanced | `get-cca-export.sh` | Requires billing export to BigQuery | Reads real billing data; better Spot detection |

Start with **`get-cca-export-asset-730.sh`** — it works immediately with no billing configuration.

---

## Prerequisites (both scripts)

1. **Google Cloud SDK** (`gcloud`, `bq`, `gsutil`) installed and authenticated
   - Install: https://cloud.google.com/sdk/docs/install
   - Authenticate:
     ```bash
     gcloud auth login
     gcloud config set project <YOUR_PROJECT_ID>
     ```
2. **`jq`** installed (used by the asset-inventory script)
   - Windows (winget): `winget install jqlang.jq`
   - macOS: `brew install jq`
   - Linux: `sudo apt-get install jq`
3. **A Bash shell** (Windows: Git Bash or WSL — the scripts are Bash, not PowerShell).

### Permissions
- **Asset Inventory script:** `roles/cloudasset.viewer` (or `roles/viewer`) on the project. The script auto-enables the Cloud Asset API if needed.
- **BigQuery script:** `roles/bigquery.dataViewer` + `roles/bigquery.jobUser` on the billing project/dataset.

---

## Option 1 (recommended): Cloud Asset Inventory

### Configuration variables — `get-cca-export-asset-730.sh`

| Variable | Default | What it does |
|----------|---------|--------------|
| `PROJECT_ID` | `your-gcp-project-id` | **Required.** The project to scan. |
| `HOURS_PER_MONTH` | `730` | Multiplier used to estimate monthly runtime hours. |
| `RUNNING_ONLY` | `"false"` | `"true"` counts only `RUNNING` instances; `"false"` counts all. |
| `OUTPUT_FILE` | `./gcp_cca_export.csv` | Path of the generated CSV. |

### Run it
```bash
chmod +x get-cca-export-asset-730.sh
# edit PROJECT_ID at the top of the file
./get-cca-export-asset-730.sh
```

### How it works
1. Checks `gcloud`/`jq`, confirms you're authenticated, sets the project.
2. Enables `cloudasset.googleapis.com` if it isn't already.
3. Lists instances: `gcloud asset list --asset-types=compute.googleapis.com/Instance`.
4. Uses `jq` to derive region (from the zone), machine type, and Spot vs On-Demand (`scheduling.provisioningModel`/`preemptible`), groups them, and writes the CCA CSV with `hours = count x 730`.

---

## Option 2 (advanced): BigQuery billing export

Use this only if you have **Detailed usage cost** export to BigQuery already configured:
https://cloud.google.com/billing/docs/how-to/export-data-bigquery-setup

### Configuration variables — `get-cca-export.sh`

| Variable | Default | What it does |
|----------|---------|--------------|
| `PROJECT_ID` | `your-gcp-project-id` | **Required.** Project that owns the billing dataset. |
| `DATASET_NAME` | `billing_data` | **Required.** BigQuery dataset holding the export. |
| `BILLING_TABLE` | `gcp_billing_export_resource_v1_...` | **Required.** The **detailed** (resource-level) export table. Find it with `bq ls <PROJECT>:<DATASET>`. |
| `HOURS_PER_MONTH` | `730` | Multiplier for the hours estimate. |
| `OUTPUT_FILE` | `./gcp_results.csv` | Path of the generated CSV. |

> **Important:** you must use the **resource-level** export table (`..._resource_v1_...`). The size column comes from `system_labels['compute.googleapis.com/machine_spec']`, which only exists in the detailed export — not the standard (`..._v1_...`) one.

### Run it
```bash
chmod +x get-cca-export.sh
# edit PROJECT_ID / DATASET_NAME / BILLING_TABLE at the top of the file
./get-cca-export.sh
```

### How it works
Runs a BigQuery query over the last full calendar month that filters to `Compute Engine`, extracts the machine type from `system_labels`, groups by region/size/pricing, counts distinct instances, and writes the CCA CSV (prefixing each row with `GCP`).

---

## Run in GCP Cloud Shell (easiest — no local install)

Cloud Shell already has `gcloud`, `bq`, and `jq`, and you're auto-authenticated, so you can skip the Prerequisites entirely.

1. Open [console.cloud.google.com](https://console.cloud.google.com) and click the **`>_`** (Activate Cloud Shell) icon top-right.
2. Upload the script: Cloud Shell **⋮ (three-dot menu) → Upload** → pick `get-cca-export-asset-730.sh` (or `get-cca-export.sh`).
3. Run it:
   ```bash
   chmod +x get-cca-export-asset-730.sh
   nano get-cca-export-asset-730.sh   # set PROJECT_ID to your project
   ./get-cca-export-asset-730.sh
   ```
4. Download the result: Cloud Shell **⋮ → Download** → type `gcp_cca_export.csv`.

Notes:
- No `gcloud auth login` needed — you're already signed in. Set the project with `gcloud config set project <YOUR_PROJECT_ID>` (or just set `PROJECT_ID` in the script).
- The script auto-enables the Cloud Asset API if needed.
- If you see a `bad interpreter: ^M` error (Windows line endings), run `sed -i 's/\r$//' get-cca-export-asset-730.sh` and retry.

---

## Limitations

- **Hours are estimated at `count x 730`.** GCP bills per vCPU/GB, not per instance-hour, so a true per-instance-hour value isn't directly available.
- **Committed Use Discounts (Reserved) are not detected.** CUDs are applied as billing credits, so committed instances appear as `On-Demand`. Spot/Preemptible instances **are** detected.
- **Asset script scans one project at a time.** For an organization-wide view, run per project (or ask me to switch it to `gcloud asset list --scope=organizations/<ORG_ID>`).
- **BigQuery script needs the detailed export** (see note above) or the `Size` column will be empty.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `No active gcloud account` | Run `gcloud auth login`. |
| `'jq' is not installed` | Install jq (see Prerequisites). |
| Empty CSV (header only) | No instances in the project, or `RUNNING_ONLY="true"` filtered them out. Check `gcloud compute instances list`. |
| `Dataset ... not found` (BigQuery) | Billing export isn't set up, or wrong `PROJECT_ID`/`DATASET_NAME`. |
| `Size` column empty (BigQuery) | You're pointing at the standard export; switch to the `..._resource_v1_...` table. |
| Region looks wrong | Scripts emit GCP short codes; verify against Sheet2 of the template. |
