# GCP — scheduled policy regeneration

Runs `generate.py` once a week as a **Cloud Run Job**, re-derives every policy
artifact from the live AMD CCA API, writes the result to a GCS bucket, and
alerts you only when a policy actually changed.

## Why there's only Terraform here

AWS gets CloudFormation and Azure gets Bicep because those are each cloud's
own template language. GCP no longer has one: **Deployment Manager shut down on
2026-03-31**, and its replacement, **Infrastructure Manager, executes Terraform
configurations**. So on GCP, Terraform *is* the native path — the file below is
both the "native" and the "alternative" answer, and you can hand the exact same
directory to Infra Manager if you'd rather Google ran it than run it yourself.

| File | |
|---|---|
| [`terraform/main.tf`](terraform/main.tf) | 16 resources, 11 variables |

---

## What gets created

- **Cloud Run Job** on cron `0 7 * * 1` (Mondays 07:00, zone configurable)
- **Cloud Scheduler job** that POSTs to the Cloud Run Admin API to start it
- **Two service accounts** — one the job runs as, one the scheduler uses
- **GCS bucket** — versioned, uniform access, public access prevention enforced,
  noncurrent versions deleted after 730 days
- **Pub/Sub topic** for the structured change report
- **Two log-based metrics + two alert policies** (only if you pass an email)

The CCA token is **not** created by this template. See below.

---

## Setup

### 1. Put the token in Secret Manager

The token never appears in the template, in `terraform.tfvars`, or in state.
Create the secret yourself first:

```bash
gcloud secrets create cca-api-key --replication-policy=automatic
```

```bash
gcloud secrets versions add cca-api-key --data-file=cca_api_key.txt
```

The config takes the secret *name*, not the value — a token passed as a
Terraform variable gets written to state in plaintext.

### 2. Enable the APIs

```bash
gcloud services enable run.googleapis.com cloudscheduler.googleapis.com secretmanager.googleapis.com pubsub.googleapis.com monitoring.googleapis.com
```

### 3. Build and push the image

Build from the **repo root** — `generate.py` lives one level above
`automation/`, and Docker can't `COPY` from outside the build context:

```bash
docker build -f automation/Dockerfile --build-arg CLOUD=gcp -t us-docker.pkg.dev/my-project/amd/policies:2026-10-21 .
```

```bash
docker push us-docker.pkg.dev/my-project/amd/policies:2026-10-21
```

Tag with a date, **not** `:latest`. A scheduled job that silently picks up a
new `:latest` is a policy generator you no longer control.

### 4. Deploy

**Directly:**

```bash
terraform -chdir=automation/gcp/terraform init
```

```bash
terraform -chdir=automation/gcp/terraform apply -var project_id=my-project -var container_image=us-docker.pkg.dev/my-project/amd/policies:2026-10-21 -var notification_email=you@example.com
```

**Or through Infrastructure Manager**, which runs the same Terraform for you
and keeps the state in Google's control plane:

```bash
gcloud infra-manager deployments apply projects/my-project/locations/us-central1/deployments/amd-iam-policies --service-account=projects/my-project/serviceAccounts/infra-manager@my-project.iam.gserviceaccount.com --local-source=automation/gcp/terraform --input-values=project_id=my-project,container_image=us-docker.pkg.dev/my-project/amd/policies:2026-10-21
```

### 5. Run it once by hand

Don't wait until Monday to find out the service account can't read the secret:

```bash
gcloud run jobs execute amd-iam-policies-weekly --region us-central1
```

```bash
gcloud run jobs executions logs read $(gcloud run jobs executions list --job amd-iam-policies-weekly --region us-central1 --limit 1 --format='value(name)') --region us-central1
```

The first run reports every file as changed — there's nothing stored to compare
against yet. That's expected, and it's also your proof the whole chain works.

---

## Where the output lands

```
gs://amd-iam-policies-<project-number>/amd-iam-policies/
  current/                     latest of each artifact — this is what you diff against
    aws/scp-deny-intel-amd-available-1.json
    azure/policy-definition-deny-intel-amd-available.json
    ...
  history/2026-10-21/          dated copy of the same, plus the CCA snapshot
  history/2026-10-21/gap-analysis-2026-10-21.md
```

```bash
gsutil ls gs://amd-iam-policies-<project-number>/amd-iam-policies/current/
```

---

## The scheduler → job hop

The one piece of this config that is easy to get wrong, and worth knowing about
before you edit it:

- The target is the **v2** Admin API,
  `https://run.googleapis.com/v2/projects/P/locations/R/jobs/JOB:run`.
- It authenticates with **`oauth_token`, not `oidc_token`**. Scheduler targets
  on `*.googleapis.com` expect an OAuth access token; an OIDC token is rejected.
  (OIDC is the right choice when the target is your *own* Cloud Run service.)
- The body is `base64encode("{}")` — the `:run` method requires a JSON body
  even though there's nothing to say in it.
- The scheduler's service account needs `roles/run.invoker` on the job, which
  `google_cloud_run_v2_job_iam_member.scheduler` grants.

The scheduler account is deliberately **not** the account the job runs as.
"May trigger the job" and "may read the CCA token" stay separate grants, so a
compromise of the trigger doesn't yield the credential.

---

## Alerting, and why there are two policies

| Alert | Fires when |
|---|---|
| `AMD IAM policies changed` | CCA now answers differently for at least one region/family |
| `AMD IAM policy regeneration failed` | The run raised an error |

Both are log-based metrics matching the exact banners `runner.py` prints, summed
hourly. The job runs weekly, so a Monday event is reported within the hour.

The failure alert matters more than it looks. A silent weekly job and a *broken*
weekly job produce identical evidence: nothing in your inbox. Roughly 50 of 52
runs legitimately produce no change, so without this policy you'd have no way to
tell "CCA agrees with last week" from "this hasn't run since March".

`runner.py` also publishes the structured report to the Pub/Sub topic. Subscribe
to it instead if you'd rather drive a workflow than read an email.

---

## Changing the schedule

Weekly is a deliberate default: AMD adds regions and instance families a few
times a year, so most runs find nothing. Daily would multiply CCA load by seven
to surface the same handful of changes a few days sooner.

| Cron | Meaning |
|---|---|
| `0 7 * * 1` | Mondays 07:00 (default) |
| `0 7 1 * *` | 1st of the month, 07:00 |
| `0 7 * * 1,4` | Mondays and Thursdays |

Unlike Azure Container Apps, Cloud Scheduler honours IANA time zones — set
`schedule_timezone` if you want local time. It's left at `Etc/UTC` so all four
clouds fire together.

---

## What this does *not* do

- **It does not apply anything.** The job regenerates artifacts into the bucket.
  Nothing is pushed to org-policies, AWS Organizations, Azure Policy or OCI IAM.
  Promoting a regenerated policy stays a human review step — the whole point of
  the change alert is to tell you a review is due.
- **It does not touch running instances.** `generate.py` only derives
  create-time guard lists.
- **It does not need project-wide secret access.** The grant is on the one
  secret, via `google_secret_manager_secret_iam_member`, not
  `roles/secretmanager.secretAccessor` at the project.

---

## Cost

Cloud Run Jobs bill only while running, so this is ~48 seconds of 1 vCPU / 1 GiB
per week plus a few MB of storage — cents per month. Cloud Scheduler's first
three jobs per month are free.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Scheduler shows `UNAUTHENTICATED` / `401` | `oidc_token` instead of `oauth_token` — `*.googleapis.com` targets need OAuth |
| Scheduler shows `PERMISSION_DENIED` / `403` | Scheduler SA missing `roles/run.invoker` on the job |
| Job starts, 403 on the secret | Secret name in `cca_secret_id` doesn't match the one you created |
| `404` from the `:run` call | v1 URI instead of v2, or job name/region mismatch |
| Every run reports all 12 files changed | Nothing in `current/` — either it's the first run, or the prefix doesn't match what you're inspecting |
| Alerts never fire | `notification_email` is empty, which skips all four alerting resources by design |
