# Automating the policy refresh

`generate.py` in the parent directory is a script a human runs. That's fine for
a one-off, but the policies it produces have a shelf life: AMD adds regions and
instance families several times a year, and every time it does, some region ×
family pair that *had* no AMD equivalent now has one — and the committed policy
quietly stops enforcing what it claims to enforce.

This directory runs the same script on a schedule, in whichever cloud you
already operate, and tells you when the answer changes.

> **This is optional.** The policy pack in `../` is complete and usable without
> any of it. Nothing here applies a policy — see
> [What none of this does](#what-none-of-this-does).

---

## Pick your cloud

| Cloud | Native template | Terraform | Compute |
|---|---|---|---|
| [**AWS**](aws/README.md) | [CloudFormation](aws/cloudformation.yaml) | [yes](aws/terraform/main.tf) | Lambda (zip) |
| [**Azure**](azure/README.md) | [Bicep](azure/main.bicep) | [yes](azure/terraform/main.tf) | Container Apps Job |
| [**GCP**](gcp/README.md) | — *(Terraform **is** native)* | [yes](gcp/terraform/main.tf) | Cloud Run Job |
| [**OCI**](oci/README.md) | — *(Terraform **is** native)* | [yes](oci/terraform/main.tf) | Functions |

You only need **one**. The job sweeps all four clouds' catalogs regardless of
where it runs — CCA is a public API, not a per-cloud service. Run it wherever
your secret store and your on-call already live.

### Why GCP and OCI have no second format

Not an omission:

- **GCP** retired Deployment Manager on **2026-03-31**. Its replacement,
  Infrastructure Manager, *executes Terraform*. There is no Google-proprietary
  template format left to write.
- **OCI Resource Manager** has always been Terraform. Upload
  `oci/terraform/` as a stack and that *is* the Oracle-native path.

So AWS and Azure get two files because those clouds genuinely have two formats.
GCP and OCI get one because they have one.

---

## How it works

```
EventBridge / Container Apps / Cloud Scheduler / Resource Scheduler
        │  weekly, Mondays 07:00 UTC
        ▼
   runner.py ──► secret store        read the CCA token (never an env var,
        │                             never in the repo, never in state)
        ├──────► generate.py         ~4,100 CCA probes across 4 clouds, ~48s
        ├──────► object store        read last week's artifacts
        │                             write this week's to current/ + history/<date>/
        ├──────► diff                 did a policy artifact actually change?
        └──────► notify               only if it did
```

[`runner.py`](runner.py) is the whole adaptation layer — four secret stores,
four object stores, four notifiers, one `run()`. `generate.py` is **unchanged**
from the version a human runs by hand; the scheduled path and the manual path
execute literally the same policy logic.

### Notify only on change

AMD moves a few times a year, so **roughly 50 of 52 runs produce no change at
all**. A job that emails weekly gets filtered into a folder nobody reads; a job
that stays silent until a policy genuinely moves gets read every time.

The diff deliberately covers **only the 12 policy artifacts** — not the CCA
snapshot and not the gap report, both of which carry a date and so differ every
single run. Diffing those would make the alert fire weekly and train everyone
to ignore it.

CSV matrices are summarised by **verdict transition**, not as raw line adds,
because an added row is *not* automatically a new denial — it may be a
newly-catalogued family CCA still has no AMD match for:

```
NEWLY DENIED (AMD equivalent now exists) [2]:
  eu-south-2 r7i: ALLOW -> DENY  (r8a)
  ap-south-2 m7i: ALLOW -> DENY  (m8a)
```

### Alert on failure too

Every cloud here gets a **second** alert for the run failing. This is less
obvious than it looks: a healthy no-change week and a job that hasn't run since
March produce identical evidence — nothing in your inbox. Without the failure
alert there is no way to distinguish them.

---

## What you supply

Three things, in every cloud:

| | |
|---|---|
| **A CCA token in the platform's secret store** | Secrets Manager / Key Vault / Secret Manager / OCI Vault. Create it **outside** the template. |
| **A container image or zip** | `package.sh` for AWS; a Docker build for the rest. |
| **An email address** (optional) | Omit it and the alerting resources aren't created at all. |

Every template takes a secret **ARN / OCID / name — never the token itself.**
A secret passed as a CloudFormation parameter is recorded in stack parameter
history; a token passed as a Terraform variable is written to state in
plaintext. The templates take references so neither can happen.

### Images

| Cloud | Build |
|---|---|
| AWS | `./automation/package.sh` → `build/lambda.zip`, no Docker |
| Azure, GCP | `docker build -f automation/Dockerfile --build-arg CLOUD=azure\|gcp -t <img> .` |
| OCI | `docker build -f automation/oci/Dockerfile -t <img> .` |

All builds run **from the repo root** — `generate.py` lives above this
directory and Docker can't `COPY` from outside the build context.

**OCI needs its own image.** Azure Container Apps Jobs and GCP Cloud Run Jobs
both run a container's entrypoint once and treat exit 0 as success, so they
share one image. OCI Functions runs the **Fn contract** — an `fdk` listener
calling a named handler — so it has its own Dockerfile and a `func.py` shim.
The work it performs is identical; only the calling convention differs.

Tag images with a date, **not** `:latest`. A scheduled job that silently picks
up a new `:latest` is a policy generator you no longer control.

---

## Running it without any cloud

The same wrapper runs locally, which is the fastest way to see what a scheduled
run would do:

```bash
python automation/runner.py --backend local --outdir ./runs --secret ~/cca_api_key.txt
```

It writes `runs/current/` and `runs/history/<date>/`, diffs against whatever is
already in `runs/current/`, and prints the change report to stdout.

You can also mix backends — read the token off your laptop while writing to a
real bucket, which is how you check your permissions are right before wiring up
a vault. Any `--secret` that names an existing file is treated as a local key
file whatever `--backend` says:

```bash
python automation/runner.py --backend aws --bucket my-bucket --secret ~/cca_api_key.txt
```

---

## Checking the templates

```bash
python automation/validate.py
```

Parses all HCL, JSON and YAML, verifies every `var.*` is declared and every
resource reference resolves in-file, and scans the whole directory for
credential-shaped literals. It is **not** a substitute for `terraform validate`
/ `az bicep build` / `cfn-lint`, which need the real toolchain — it's the check
that runs anywhere, and it catches the errors that actually bite when copying
templates between clouds.

---

## Schedule

All four default to **Mondays 07:00 UTC**. Weekly is deliberate: daily would
multiply CCA load by seven to surface the same handful of changes a few days
sooner.

Cloud Scheduler honours IANA time zones; Container Apps Jobs and OCI Resource
Scheduler are **UTC-only**. Left at UTC everywhere so all four fire together.

---

## What none of this does

- **It does not apply anything.** The job regenerates artifacts into object
  storage. Nothing is pushed to AWS Organizations, Azure Policy, GCP
  org-policies or OCI IAM. **Promoting a regenerated policy stays a human
  review step** — the whole point of the change alert is to tell you a review
  is due. An automation that silently widened a Deny policy across an
  organisation every Monday is not something anyone should want.
- **It does not touch running instances.** `generate.py` derives create-time
  guard lists; the enforcement model in `../` is unchanged by running it on a
  schedule.
- **It does not change the carve-outs.** A family with no AMD equivalent, and a
  region with no AMD availability, stay allowed — that's a property of the CCA
  verdict, not of how often you ask for it.
