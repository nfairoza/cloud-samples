# OCI — scheduled policy regeneration

Runs `generate.py` once a week as an **OCI Function**, re-derives every policy
artifact from the live AMD CCA API, writes the result to an Object Storage
bucket, and publishes to a Notifications topic only when a policy actually
changed.

## Why there's only Terraform here

As on GCP, that's not a gap. **OCI Resource Manager *is* Terraform** — there is
no separate Oracle-proprietary template format to translate into, the way
CloudFormation exists on AWS and Bicep on Azure. Upload this directory as a
Resource Manager stack and it's the Oracle-native deployment path.

| File | |
|---|---|
| [`terraform/main.tf`](terraform/main.tf) | Functions app, schedule, bucket, topic, IAM |
| [`Dockerfile`](Dockerfile) | OCI-specific image — **not** the shared `../Dockerfile` |
| [`func.py`](func.py) | Fn handler shim |
| [`func.yaml`](func.yaml) | For deploying with the Fn CLI instead of Terraform |

---

## OCI is the one cloud that needs its own image

Azure Container Apps Jobs and GCP Cloud Run Jobs both run a container's
entrypoint once and treat exit 0 as success, so those two share
`automation/Dockerfile`. **OCI Functions does not work that way.** Fn — which
Functions is built on — expects the image to start the FDK listener, which then
calls a named handler per invocation:

```
ENTRYPOINT ["/python/bin/fdk", "/function/func.py", "handler"]
```

with a handler of the form `def handler(ctx, data: io.BytesIO = None)`. The
shared image ends `ENTRYPOINT ["python", "/app/runner.py"]`, which would start,
do the work, exit — and never become ready as a function.

So OCI gets [`Dockerfile`](Dockerfile) and [`func.py`](func.py). The work itself
is still `runner.run()`, byte-identical to what the other three clouds execute;
only the calling convention differs. Building `../Dockerfile` with `CLOUD=oci`
now fails loudly rather than producing an image that deploys and never runs.

Two other OCI-specific shapes:

- **Functions requires a VCN subnet.** There is no "no networking needed" mode.
  The config takes an existing subnet OCID rather than inventing a VCN you
  didn't ask for. It needs egress to `api.epycadvisory.amd.com`, so a private
  subnet works only through a **NAT gateway** — a service gateway alone isn't
  enough, since CCA isn't an OCI service endpoint.
- **The 300-second timeout is a hard ceiling.** A full four-cloud sweep measures
  ~48s, nearly all of it waiting on CCA, so there's headroom — but unlike the
  other three clouds there's no room to raise it. That's what `--cloud` is for;
  see *If the sweep ever outgrows 300s* below.

---

## Setup

### 1. Put the token in Vault

The token never appears in the template or in Terraform state. The OCI secret
API takes base64 content:

```bash
oci vault secret create-base64 --compartment-id <COMPARTMENT> --vault-id <VAULT> --secret-name cca-api-key --key-id <KEY> --secret-content-content "$(base64 -w0 cca_api_key.txt)"
```

Note the resulting **secret OCID** — that's what `cca_secret_ocid` takes. The
config takes the OCID, not the value: a token passed as a Terraform variable
gets written to state in plaintext.

### 2. Build and push the image

Build from the **repo root** — `generate.py` lives two levels above
`automation/oci/`, and Docker can't `COPY` from outside the build context:

```bash
docker build -f automation/oci/Dockerfile -t iad.ocir.io/<namespace>/amd/policies:2026-10-21 .
```

```bash
docker push iad.ocir.io/<namespace>/amd/policies:2026-10-21
```

Log in to OCIR first with `docker login iad.ocir.io` — username
`<namespace>/<your-username>`, password an **auth token**, not your console
password. Tag with a date, **not** `:latest`.

### 3. Deploy

**Directly:**

```bash
terraform -chdir=automation/oci/terraform init
```

```bash
terraform -chdir=automation/oci/terraform apply -var tenancy_ocid=<T> -var compartment_ocid=<C> -var subnet_ocid=<SUBNET> -var cca_secret_ocid=<SECRET> -var container_image=iad.ocir.io/<ns>/amd/policies:2026-10-21 -var notification_email=you@example.com
```

**Or as a Resource Manager stack:**

```bash
oci resource-manager stack create --compartment-id <C> --config-source automation/oci/terraform --terraform-version 1.5.x --display-name amd-iam-policies
```

Then run a plan and an apply job against the stack from the console or CLI.

### 4. Run it once by hand

Don't wait until Monday to find out the resource principal can't read the
secret:

```bash
oci fn function invoke --function-id <FUNCTION_OCID> --file - --body ''
```

The OCID is in the `function_ocid` output. The first run reports every file as
changed — there's nothing stored to compare against yet. That's expected, and
it's also your proof the whole chain works.

---

## Where the output lands

```
<bucket>/amd-iam-policies/
  current/                     latest of each artifact — this is what you diff against
    aws/scp-deny-intel-amd-available-1.json
    azure/policy-definition-deny-intel-amd-available.json
    ...
  history/2026-10-21/          dated copy of the same, plus the CCA snapshot
  history/2026-10-21/gap-analysis-2026-10-21.md
```

```bash
oci os object list -bn amd-iam-policies-artifacts --prefix amd-iam-policies/current/
```

---

## Two dynamic groups, on purpose

OCI has no Deny verb and no per-resource identity attached by default, so both
principals here are dynamic groups:

| Group | Matches | Can |
|---|---|---|
| `…-fn-dg` | `resource.type = 'fnfunc'` | read the one secret, manage objects in the one bucket, publish to the one topic |
| `…-sched-dg` | `resource.type = 'resourceschedule'` | `manage functions-family` — invoke the function, nothing else |

The scheduler group is deliberately separate from the function's. "May trigger
the job" and "may read the CCA token" stay separate grants, so a compromise of
the trigger doesn't yield the credential.

`manage objects` rather than `read objects` on the bucket is also deliberate:
the diff requires reading last week's copy as well as writing this week's.

---

## Before you apply: confirm functions are schedulable

Resource Scheduler's `action` enum is `START_RESOURCE` / `STOP_RESOURCE` /
`BACKUP_RESOURCE` — it models a function the same way it models a stoppable VM,
and *starting* a function means invoking it. Oracle documents compute instances
and autonomous databases explicitly and publishes a separate "Scheduling a
Function" guide, but the authoritative per-tenancy answer is:

```bash
oci resource-scheduler resource-type-collection list-resource-types
```

If `fnfunc` isn't listed in your tenancy or region, swap the trigger for an
**OCI Events rule on a scheduled Notifications topic**, or simply invoke the
function from any existing cron host:

```bash
oci fn function invoke --function-id <FUNCTION_OCID> --file - --body ''
```

Everything else in the config — the function, the IAM, the bucket, the topic —
is unaffected by which trigger you use.

---

## If the sweep ever outgrows 300s

300 seconds is the OCI Functions maximum, so this is the one cloud where you
can't just raise the timeout. If CCA slows to the point of timing out, split the
sweep across several single-cloud schedules rather than trying to raise it:

```
CLOUDS = "AWS"      → one schedule
CLOUDS = "AZURE"    → another
```

Each writes only its own artifacts, and `runner.py` treats a missing file from a
narrowed run as "not generated", not as an error. Azure is the slow one — 2,630
probes against AWS's 498.

---

## Changing the schedule

Weekly is a deliberate default: AMD adds regions and instance families a few
times a year, so most runs find nothing. Daily would multiply CCA load by seven
to surface the same handful of changes a few days sooner.

Resource Scheduler evaluates cron in **UTC only** and does not adjust for
daylight saving.

| Cron | Meaning |
|---|---|
| `0 7 * * 1` | Mondays 07:00 UTC (default) |
| `0 7 1 * *` | 1st of the month, 07:00 UTC |
| `0 7 * * 1,4` | Mondays and Thursdays |

---

## What this does *not* do

- **It does not apply anything.** The function regenerates artifacts into the
  bucket. Nothing is pushed to OCI IAM, AWS Organizations, Azure Policy or
  org-policies. Promoting a regenerated policy stays a human review step — the
  whole point of the change notification is to tell you a review is due.
- **It does not touch running instances.** `generate.py` only derives
  create-time guard lists.
- **It does not create a VCN.** You supply an existing subnet.

---

## Cost

Functions bill per invocation and per GB-second, so ~48 seconds of a 1 GB
function once a week sits inside the monthly free allowance. The bucket holds a
few MB. The only line item worth noting is the NAT gateway, if you stand one up
solely for this — in which case share an existing one.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Function deploys but every invoke times out | Built from `automation/Dockerfile` instead of `automation/oci/Dockerfile` — wrong entrypoint, FDK never starts |
| `Error invoking function. status: 502` | Handler raised; check function logs for the traceback |
| Hangs then times out at 300s with no CCA response | Subnet has no route to the internet — needs a NAT gateway, not just a service gateway |
| 404 reading the secret | `cca_secret_ocid` points at the secret in a different compartment than the policy scopes |
| Schedule created but never fires | `fnfunc` not a supported type in your tenancy — see *Before you apply* |
| Every run reports all 12 files changed | Nothing in `current/` — either it's the first run, or the prefix doesn't match what you're inspecting |
