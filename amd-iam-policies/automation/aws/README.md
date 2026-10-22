# AWS — scheduled policy regeneration

Runs `generate.py` once a week as a **Lambda function**, re-derives every policy
artifact from the live AMD CCA API, writes the result to S3, and sends an SNS
notification only when a policy actually changed.

Two equivalent implementations — pick one, not both:

| | File | Use when |
|---|---|---|
| **CloudFormation** (native) | [`cloudformation.yaml`](cloudformation.yaml) | You deploy AWS with CFN / StackSets |
| **Terraform** | [`terraform/main.tf`](terraform/main.tf) | You deploy everything with Terraform |

Running both creates two of everything.

---

## What gets created

- **Lambda** (`python3.13`, arm64, 512 MB, 300 s) on cron `0 7 ? * MON *` (UTC)
- **EventBridge Scheduler schedule** — or a classic Events rule, see below
- **S3 bucket** — versioned, SSE-S3, public access blocked, TLS-only bucket
  policy, noncurrent versions expired after 730 days, `DeletionPolicy: Retain`
- **SNS topic** (+ email subscription if you pass an address)
- **CloudWatch log group** (90 days) and a **failure alarm**
- **IAM role** scoped to one secret, one bucket prefix, one topic, one log group

The CCA token is **not** created by either template. See below.

---

## Setup

### 1. Put the token in Secrets Manager

```bash
aws secretsmanager create-secret --name amd/cca-api-key --secret-string file://cca_api_key.txt
```

Either a bare JWT or `{"CCA_API_KEY":"..."}` works — `runner.py` accepts both.

Both templates take the secret **ARN**, never the value. A secret passed as a
CloudFormation parameter is recorded in the stack's parameter history and
readable by anyone with `DescribeStacks`; a token passed as a Terraform variable
is written to state in plaintext.

### 2. Build the deployment zip

No Docker here — Lambda takes a plain zip, and `boto3` is already in the
runtime, so there's nothing to vendor:

```bash
./automation/package.sh
```

That writes `automation/build/lambda.zip` containing exactly two files,
`generate.py` and `runner.py`. The zip is built deterministically (fixed
timestamps, sorted entries), so an unchanged source tree produces a
byte-identical artifact and Terraform won't redeploy a function that didn't
change.

**CloudFormation also needs it in S3** — `AWS::Lambda::Function` can't take a
local file:

```bash
./automation/package.sh --upload my-deploy-bucket
```

Terraform uploads the zip directly, so this step is CFN-only.

### 3. Deploy

**CloudFormation:**

```bash
aws cloudformation deploy --stack-name amd-iam-policies --template-file automation/aws/cloudformation.yaml --capabilities CAPABILITY_IAM --parameter-overrides CodeS3Bucket=my-deploy-bucket CcaSecretArn=arn:aws:secretsmanager:us-east-1:111122223333:secret:amd/cca-api-key-AbCdEf NotificationEmail=you@example.com
```

**Terraform:**

```bash
terraform -chdir=automation/aws/terraform init
```

```bash
terraform -chdir=automation/aws/terraform apply -var cca_secret_arn=arn:aws:secretsmanager:us-east-1:111122223333:secret:amd/cca-api-key-AbCdEf -var notification_email=you@example.com
```

Confirm the SNS subscription from your inbox — AWS won't deliver until you do.

### 4. Run it once by hand

Don't wait until Monday to find out the role can't read the secret:

```bash
aws lambda invoke --function-name amd-iam-policies-generate /dev/stdout
```

The first run reports every file as changed — there's nothing stored to compare
against yet. That's expected, and it's also your proof the whole chain works.

---

## Where the output lands

```
s3://<bucket>/amd-iam-policies/
  current/                     latest of each artifact — this is what you diff against
    aws/scp-deny-intel-amd-available-1.json
    azure/policy-definition-deny-intel-amd-available.json
    ...
  history/2026-10-21/          dated copy of the same, plus the CCA snapshot
  history/2026-10-21/gap-analysis-2026-10-21.md
```

```bash
aws s3 ls s3://<bucket>/amd-iam-policies/current/ --recursive
```

---

## EventBridge Scheduler vs. Events rule

The default is **EventBridge Scheduler** (`AWS::Scheduler::Schedule`): it has a
real retry policy and doesn't need a resource-based permission on the Lambda.

It isn't available in every partition, though — notably **GovCloud, China,
`ca-west-1`, `il-central-1` and `ap-southeast-5`**. In those regions switch to
the classic CloudWatch Events rule, which takes the same `cron()` expression:

```bash
--parameter-overrides SchedulerType=EventsRule
```

```bash
-var use_eventbridge_scheduler=false
```

Both templates carry both paths behind a condition, so this is a one-parameter
change rather than a different template.

---

## Alerting

`runner.py` publishes the change report to SNS on AWS, so the change path needs
no extra wiring — the topic is the notification. The **failure alarm** is what
needed adding.

A silent weekly job and a *broken* weekly job produce identical evidence:
nothing in your inbox. Roughly 50 of 52 runs legitimately produce no change, so
without the alarm you'd have no way to tell "CCA agrees with last week" from
"this hasn't run since March". The alarm fires on the Lambda `Errors` metric
summed daily, with `TreatMissingData: notBreaching` so a quiet week isn't an
alarm.

---

## Changing the schedule

Weekly is a deliberate default: AMD adds regions and instance families a few
times a year, so most runs find nothing. Daily would multiply CCA load by seven
to surface the same handful of changes a few days sooner.

| Expression | Meaning |
|---|---|
| `cron(0 7 ? * MON *)` | Mondays 07:00 UTC (default) |
| `cron(0 7 1 * ? *)` | 1st of the month, 07:00 UTC |
| `cron(0 7 ? * MON,THU *)` | Mondays and Thursdays |

---

## What this does *not* do

- **It does not apply anything.** The function regenerates artifacts into S3.
  Nothing is pushed to Organizations, Azure Policy, org-policies or OCI IAM.
  Promoting a regenerated policy stays a human review step — the whole point of
  the change notification is to tell you a review is due.
- **It does not touch running instances.** `generate.py` only derives
  create-time guard lists.
- **It does not need `logs:*` account-wide.** The role is scoped to this
  function's own log group, not the `AWSLambdaBasicExecutionRole` managed
  policy.

---

## Cost

Lambda bills per 100 ms, so this is ~48 seconds of a 512 MB arm64 function per
week — inside the free tier. S3 holds a few MB. The log group at 90-day
retention is the largest line item and is still cents per month.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `AccessDeniedException` on `GetSecretValue` | `CcaSecretArn` points at a different secret, or the ARN includes the wrong 6-char suffix |
| Task timed out after 300 s | CCA is slow — narrow the sweep with `Clouds=AWS` or raise `Timeout` (Lambda's ceiling is 900 s) |
| `Resource type AWS::Scheduler::Schedule is not supported` | Partition without EventBridge Scheduler — set `SchedulerType=EventsRule` |
| No email ever arrives | SNS subscription not confirmed |
| Every run reports all 12 files changed | Nothing in `current/` — either it's the first run, or the prefix doesn't match what you're inspecting |
| Terraform wants to replace the Lambda on every apply | `package.sh` wasn't used, so the zip isn't deterministic |
