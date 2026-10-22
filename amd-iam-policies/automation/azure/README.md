# Azure — scheduled policy regeneration

Runs `generate.py` once a week as a **Container Apps Job**, re-derives every
policy artifact from the live AMD CCA API, writes the result to blob storage,
and alerts you only when a policy actually changed.

Two equivalent implementations — pick one, not both:

| | File | Use when |
|---|---|---|
| **Bicep** (native) | [`main.bicep`](main.bicep) + [`vault-access.bicep`](vault-access.bicep) | You deploy Azure with ARM/Bicep |
| **Terraform** | [`terraform/main.tf`](terraform/main.tf) | You deploy everything with Terraform |

Running both creates two of everything.

---

## What gets created

- **User-assigned managed identity** — the only principal that touches the token
- **Container Apps Job** on cron `0 7 * * 1` (Mondays 07:00 **UTC**)
- **Container Apps environment** + **Log Analytics workspace** (90-day retention)
- **Storage account** + `policies` container — versioned, 365-day soft delete,
  public access off, **shared keys disabled**
- **Two alert rules** (only if you pass an email) — one for failure, one for change
- **Role assignments** — *Key Vault Secrets User* on your vault,
  *Storage Blob Data Contributor* on the new account

The CCA token is **not** created by either template. See below.

---

## Setup

### 1. Put the token in Key Vault

The token never appears in the template, in deployment parameters, or in the
image. Create the secret yourself first:

```bash
az keyvault secret set --vault-name <VAULT> --name cca-api-key --file cca_api_key.txt
```

> The vault must use **Azure RBAC** (`enableRbacAuthorization: true`). On a
> vault still using access policies the role assignment deploys cleanly but has
> no effect, and the first run fails with a 403. Check this first if the job
> can't read the token.

Check which mode your vault is in:

```bash
az keyvault show -n <VAULT> --query properties.enableRbacAuthorization
```

### 2. Build and push the image

Build from the **repo root** — `generate.py` lives one level above
`automation/`, and Docker can't `COPY` from outside the build context:

```bash
docker build -f automation/Dockerfile --build-arg CLOUD=azure -t myacr.azurecr.io/amd-iam-policies:2026-10-21 .
```

```bash
docker push myacr.azurecr.io/amd-iam-policies:2026-10-21
```

Tag with a date, **not** `:latest`. A scheduled job that silently picks up a
new `:latest` is a policy generator you no longer control.

If your registry isn't public, grant the job's identity `AcrPull` on it — or
use an admin-enabled registry and add a `registry` block. The templates assume
a pullable image to keep the registry story out of the policy story.

### 3. Deploy

**Bicep:**

```bash
az deployment group create -g amd-iam-policies-rg -f automation/azure/main.bicep -p containerImage=myacr.azurecr.io/amd-iam-policies:2026-10-21 ccaKeyVaultName=my-vault notificationEmail=you@example.com
```

If the vault lives in a different resource group, add
`ccaKeyVaultResourceGroup=<RG>`.

**Terraform:**

```bash
terraform -chdir=automation/azure/terraform init
```

```bash
terraform -chdir=automation/azure/terraform apply -var container_image=myacr.azurecr.io/amd-iam-policies:2026-10-21 -var cca_key_vault_name=my-vault -var cca_key_vault_resource_group=my-vault-rg -var notification_email=you@example.com
```

### 4. Run it once by hand

Don't wait until Monday to find out the identity can't read the vault:

```bash
az containerapp job start -n amd-iam-policies-weekly -g amd-iam-policies-rg
```

Watch it:

```bash
az containerapp job execution list -n amd-iam-policies-weekly -g amd-iam-policies-rg -o table
```

The first run reports every file as changed — there's nothing stored to
compare against yet. That's expected, and it's also your proof the whole chain
works.

---

## Where the output lands

```
<container>/amd-iam-policies/
  current/                     latest of each artifact — this is what you diff against
    aws/scp-deny-intel-amd-available-1.json
    azure/policy-definition-deny-intel-amd-available.json
    ...
  history/2026-10-21/          dated copy of the same, plus the CCA snapshot
  history/2026-10-21/gap-analysis-2026-10-21.md
```

```bash
az storage blob list --account-name <ACCOUNT> -c policies --prefix amd-iam-policies/current --auth-mode login -o table
```

`--auth-mode login` is required — the account has shared keys disabled, so your
own AD identity authenticates the call. You'll need *Storage Blob Data Reader*
on the account to list it.

---

## Alerting, and why there are two rules

`runner.py` publishes change reports through SNS on AWS, Pub/Sub on GCP and ONS
on OCI. It has **no Azure notifier** — on Azure the report goes to stdout and
lands in Log Analytics. The `policy-changed` alert rule is therefore what
actually delivers it. Without that rule, Azure would be the one cloud where a
policy change is silent.

| Rule | Severity | Fires when |
|---|---|---|
| `amd-iam-policies-policy-changed` | 3 | CCA now answers differently for at least one region/family |
| `amd-iam-policies-job-failed` | 2 | The run raised an error |

Both evaluate hourly over a 1-day window. The job runs weekly, so a Monday
event is reported within the hour.

The failure alert matters more than it looks. A silent weekly job and a
*broken* weekly job produce identical evidence: nothing in your inbox. Roughly
50 of 52 runs legitimately produce no change, so without this rule you would
have no way to tell "CCA agrees with last week" from "this hasn't run since
March".

Logs, if you'd rather read them directly:

```bash
az monitor log-analytics query -w <WORKSPACE_ID> --analytics-query 'ContainerAppConsoleLogs_CL | where TimeGenerated > ago(7d) | order by TimeGenerated asc | project TimeGenerated, Log_s'
```

---

## Changing the schedule

Weekly is a deliberate default: AMD adds regions and instance families a few
times a year, so most runs find nothing. Daily would multiply CCA load by seven
to surface the same handful of changes a few days sooner.

Bicep `cronExpression` / Terraform `cron_expression`, **UTC**:

| Cron | Meaning |
|---|---|
| `0 7 * * 1` | Mondays 07:00 (default) |
| `0 7 1 * *` | 1st of the month, 07:00 |
| `0 7 * * 1,4` | Mondays and Thursdays |

---

## What this does *not* do

- **It does not apply anything.** The job regenerates artifacts into blob
  storage. Nothing is pushed to Azure Policy, AWS Organizations, GCP
  org-policies or OCI IAM. Promoting a regenerated policy stays a human review
  step — the whole point of the change alert is to tell you a review is due.
- **It does not touch running VMs.** `generate.py` only derives create-time
  guard lists.
- **It does not need the job to read its own output.** The identity has
  *Blob Data Contributor* because the diff requires reading last week's copy.
  That's the only reason it isn't read-only.

---

## Cost

Container Apps Jobs scale to zero between runs, so you pay for ~48 seconds of
0.5 vCPU / 1 GiB per week plus a few MB of blob storage. The Log Analytics
workspace at 90-day retention is the largest line item and is still cents per
month at this volume.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| 403 reading the secret on first run | Vault is on access policies, not RBAC — see step 1 |
| `KeyBasedAuthenticationNotPermitted` during `terraform apply` | `storage_use_azuread = true` missing from the provider block (it's already set in `main.tf`) |
| Job created but never fires | Cron is UTC, not local — check the next execution time |
| Every run reports all 12 files changed | Nothing in `current/` — either it's the first run, or the prefix/container doesn't match what you're inspecting |
| `unsupported argument: storage_account_id` | azurerm provider older than 4.11 |
