###############################################################################
# Weekly AMD IAM policy regeneration - GCP.
#
# Terraform is the ONLY implementation here, and that is not a gap. Google shut
# down Deployment Manager on 2026-03-31; its replacement, Infrastructure
# Manager, executes Terraform configurations. So on GCP, Terraform IS the
# native IaC path - there is no separate Google-proprietary template format
# left to offer the way CloudFormation exists on AWS and Bicep on Azure.
#
# Run it directly:
#   terraform init
#   terraform apply -var project_id=my-project \
#     -var container_image=us-docker.pkg.dev/my-project/amd/policies:2026-10-21
#
# Or hand this same directory to Infrastructure Manager, which runs it for you:
#   gcloud infra-manager deployments apply \
#     projects/<P>/locations/<L>/deployments/amd-iam-policies \
#     --service-account=projects/<P>/serviceAccounts/<SA> \
#     --local-source=automation/gcp/terraform \
#     --input-values=project_id=<P>,container_image=<IMG>
#
# Image is built from ../../Dockerfile with CLOUD=gcp, from the repo root:
#   docker build -f automation/Dockerfile --build-arg CLOUD=gcp -t <img> .
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ------------------------------------------------------------------ variables

variable "project_id" {
  type        = string
  description = "Project hosting the automation. Unrelated to which cloud regions the policies cover - the CCA sweep is global either way."
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "name_prefix" {
  type    = string
  default = "amd-iam-policies"
}

variable "container_image" {
  type        = string
  description = "Image built from automation/Dockerfile with CLOUD=gcp. Tag with a date, not :latest - a scheduled job that silently picks up a new :latest is a policy generator you no longer control."
}

variable "cca_secret_id" {
  type        = string
  default     = "cca-api-key"
  description = <<-EOT
    Name of an EXISTING Secret Manager secret holding the CCA JWT. Create it
    outside Terraform:
      gcloud secrets create cca-api-key --replication-policy=automatic
      gcloud secrets versions add cca-api-key --data-file=cca_api_key.txt
    Passing the token as a Terraform variable would write it to state in
    plaintext, which is why this takes a secret name and not the token.
  EOT
}

variable "schedule" {
  type        = string
  default     = "0 7 * * 1"
  description = "Weekly, Mondays 07:00 in schedule_timezone."
}

variable "schedule_timezone" {
  type        = string
  default     = "Etc/UTC"
  description = "Cloud Scheduler honours IANA zones, unlike Container Apps which is UTC-only. Left at UTC so all four clouds fire together."
}

variable "clouds" {
  type        = string
  default     = "AWS,AZURE,GCP,OCI"
  description = "Restrict the sweep. Leave all four unless you only care about one."
}

variable "notification_email" {
  type        = string
  default     = ""
  description = "Optional address for change and failure notifications. Empty disables both."
}

variable "insecure_tls" {
  type        = bool
  default     = false
  description = "Set true only behind a TLS-intercepting proxy."
}

variable "artifact_retention_days" {
  type        = number
  default     = 730
  description = "How long superseded artifact versions are kept."
}

locals {
  notify_on = var.notification_email == "" ? 0 : 1
  job_name  = "${var.name_prefix}-weekly"

  args = concat(
    [
      "--backend", "gcp",
      "--bucket", google_storage_bucket.artifacts.name,
      "--prefix", var.name_prefix,
      "--secret", "projects/${var.project_id}/secrets/${var.cca_secret_id}/versions/latest",
      "--notify", google_pubsub_topic.changes.id,
      "--cloud", var.clouds,
    ],
    var.insecure_tls ? ["--insecure"] : []
  )
}

data "google_project" "this" {}

# ------------------------------------------------------------------- identity

resource "google_service_account" "runner" {
  account_id   = "${substr(var.name_prefix, 0, 24)}-sa"
  display_name = "AMD IAM policy generator"
  description  = "Runs the weekly CCA sweep. Reads one secret, writes one bucket, publishes one topic."
}

# Scoped to the one secret, not roles/secretmanager.secretAccessor project-wide.
resource "google_secret_manager_secret_iam_member" "runner" {
  secret_id = var.cca_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runner.email}"
}

# objectAdmin rather than objectViewer: the job reads last week's artifacts to
# diff against and writes this week's. Scoped to this bucket only.
resource "google_storage_bucket_iam_member" "runner" {
  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.runner.email}"
}

resource "google_pubsub_topic_iam_member" "runner" {
  topic  = google_pubsub_topic.changes.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.runner.email}"
}

# ------------------------------------------------------------------ artifacts

resource "google_storage_bucket" "artifacts" {
  # Bucket names are globally unique; the project number keeps this stable
  # across re-applies without a random suffix that would churn on destroy.
  name     = "${var.name_prefix}-${data.google_project.this.number}"
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # The bucket is the audit trail of what each week's policy looked like.
  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = var.artifact_retention_days
    }
    action {
      type = "Delete"
    }
  }
}

# --------------------------------------------------------------- notification

resource "google_pubsub_topic" "changes" {
  name = "${var.name_prefix}-changes"
}

# Pub/Sub cannot deliver to a person. runner.py publishes the structured change
# report to the topic for anything downstream that wants to consume it, and
# also prints the same report to stdout - which lands in Cloud Logging, where
# the alert policies below can turn it into an email. Subscribe to the topic
# instead if you would rather drive a workflow than read a message.

resource "google_monitoring_notification_channel" "email" {
  count        = local.notify_on
  display_name = "AMD IAM policy owner"
  type         = "email"
  labels = {
    email_address = var.notification_email
  }
}

# ------------------------------------------------------------------------ job

resource "google_cloud_run_v2_job" "weekly" {
  name     = local.job_name
  location = var.region

  deletion_protection = false

  template {
    task_count = 1

    template {
      service_account = google_service_account.runner.email

      # A full four-cloud sweep measured ~48s, nearly all of it waiting on
      # CCA. 900s absorbs a slow CCA day without letting a hung call run on.
      timeout     = "900s"
      max_retries = 2

      containers {
        image = var.container_image
        args  = local.args

        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }
      }
    }
  }

  depends_on = [
    google_secret_manager_secret_iam_member.runner,
    google_storage_bucket_iam_member.runner,
    google_pubsub_topic_iam_member.runner,
  ]
}

# ------------------------------------------------------------------- schedule
#
# Cloud Scheduler POSTs to the Cloud Run Admin API to start an execution. It
# gets its own service account, deliberately distinct from the one the job runs
# as, so "may trigger the job" and "may read the CCA token" are separate grants
# - a compromise of the trigger does not yield the credential.

resource "google_service_account" "scheduler" {
  account_id   = "${substr(var.name_prefix, 0, 21)}-sched"
  display_name = "AMD IAM policy scheduler"
  description  = "Triggers the weekly job. Cannot read the token or the bucket."
}

resource "google_cloud_run_v2_job_iam_member" "scheduler" {
  name     = google_cloud_run_v2_job.weekly.name
  location = google_cloud_run_v2_job.weekly.location
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}

resource "google_cloud_scheduler_job" "weekly" {
  name        = local.job_name
  region      = var.region
  description = "Weekly AMD CCA policy regeneration"
  schedule    = var.schedule
  time_zone   = var.schedule_timezone

  # The job itself times out at 900s; there is no value in Scheduler waiting
  # longer than that for the :run call, which returns as soon as the execution
  # is created rather than when it finishes.
  attempt_deadline = "320s"

  retry_config {
    retry_count = 2
  }

  http_target {
    http_method = "POST"
    # v2 Admin API. oauth_token, not oidc_token: *.googleapis.com targets
    # expect an OAuth access token, and an OIDC token is rejected here.
    uri  = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.weekly.name}:run"
    body = base64encode("{}")

    headers = {
      "Content-Type" = "application/json"
    }

    oauth_token {
      service_account_email = google_service_account.scheduler.email
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.scheduler]
}

# ------------------------------------------------------------------- alerting
#
# Two policies, because they carry different news. Without the failure one, a
# healthy no-change week and a job that has not run since March produce
# identical evidence: nothing in your inbox.

resource "google_logging_metric" "failed" {
  count  = local.notify_on
  name   = "${var.name_prefix}-failed"
  filter = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name="${google_cloud_run_v2_job.weekly.name}"
    (textPayload:"FAILED:" OR textPayload:"Traceback (most recent call last)")
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_logging_metric" "changed" {
  count = local.notify_on
  name  = "${var.name_prefix}-changed"
  # The exact banner runner.py prints when, and only when, a policy artifact
  # differs from the stored copy.
  filter = <<-EOT
    resource.type="cloud_run_job"
    resource.labels.job_name="${google_cloud_run_v2_job.weekly.name}"
    textPayload:"AMD IAM policies changed"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_alert_policy" "failed" {
  count        = local.notify_on
  display_name = "AMD IAM policy regeneration failed"
  combiner     = "OR"

  documentation {
    content = "The weekly CCA sweep raised an error. The previously generated policies in the bucket are unchanged and still valid."
  }

  conditions {
    display_name = "run failed"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.failed[0].name}\" AND resource.type=\"cloud_run_job\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "3600s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]
}

resource "google_monitoring_alert_policy" "changed" {
  count        = local.notify_on
  display_name = "AMD IAM policies changed"
  combiner     = "OR"

  documentation {
    content = "CCA now answers differently for at least one region/family. Review the diff in the job log, then re-upload the changed artifacts as described in each cloud README."
  }

  conditions {
    display_name = "policy artifact changed"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.changed[0].name}\" AND resource.type=\"cloud_run_job\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "3600s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]
}

# -------------------------------------------------------------------- outputs

output "job_name" {
  value = google_cloud_run_v2_job.weekly.name
}

output "artifact_bucket" {
  description = "Where generated policies land (current/ and history/<date>/)"
  value       = google_storage_bucket.artifacts.name
}

output "topic" {
  value = google_pubsub_topic.changes.id
}

output "runner_service_account" {
  value = google_service_account.runner.email
}

output "manual_run" {
  description = "Run it now instead of waiting for Monday"
  value       = "gcloud run jobs execute ${google_cloud_run_v2_job.weekly.name} --region ${var.region}"
}

output "read_results" {
  value = "gsutil ls gs://${google_storage_bucket.artifacts.name}/${var.name_prefix}/current/"
}
