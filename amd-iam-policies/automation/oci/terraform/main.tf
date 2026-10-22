###############################################################################
# Weekly AMD IAM policy regeneration - OCI.
#
# Terraform is the only implementation here, and as on GCP that is the native
# path rather than a gap: OCI Resource Manager IS Terraform. Upload this
# directory as a Resource Manager stack and it is the Oracle-native deployment
# format, with no separate proprietary template language to translate into.
#
# Run it directly:
#   terraform init
#   terraform apply -var tenancy_ocid=... -var compartment_ocid=... \
#     -var container_image=iad.ocir.io/<ns>/amd/policies:2026-10-21 \
#     -var subnet_ocid=...
#
# Or zip it and hand it to Resource Manager:
#   oci resource-manager stack create --compartment-id <C> \
#     --config-source automation/oci/terraform --terraform-version 1.5.x
#
# Image is built from ../Dockerfile - OCI's own, NOT the shared one the other
# three clouds use - from the repo root:
#   docker build -f automation/oci/Dockerfile -t <img> .
#
# Three OCI-specific shapes worth knowing before reading on:
#
#   * Functions needs a VCN subnet. Unlike Lambda / Cloud Run / Container Apps,
#     there is no "no networking required" mode, so this config takes an
#     existing subnet OCID rather than inventing a VCN you did not ask for.
#   * Functions runs the Fn contract, not a plain container command, so OCI
#     gets its own image and a func.py handler shim. See ../Dockerfile.
#   * Resource Scheduler invokes a function with START_RESOURCE, not an
#     "invoke" action - and it acts as a resource principal, which is why the
#     dynamic group and policy below exist.
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0"
    }
  }
}

provider "oci" {
  region = var.region
}

# ------------------------------------------------------------------ variables

variable "tenancy_ocid" {
  type        = string
  description = "Root tenancy OCID. Needed because the dynamic group and the policy that lets Resource Scheduler invoke the function are both tenancy-level objects."
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment for the function, bucket, vault secret and schedule."
}

variable "region" {
  type        = string
  default     = "us-ashburn-1"
  description = "Region hosting the automation. Unrelated to which cloud regions the policies cover - the CCA sweep is global either way."
}

variable "name_prefix" {
  type    = string
  default = "amd-iam-policies"
}

variable "container_image" {
  type        = string
  description = "Image in OCIR, built from automation/oci/Dockerfile (the Fn-contract one, not the shared automation/Dockerfile). Tag with a date, not :latest - a scheduled job that silently picks up a new :latest is a policy generator you no longer control."
}

variable "subnet_ocid" {
  type        = string
  description = <<-EOT
    Existing subnet for the Functions application. It needs egress to the
    public internet to reach api.epycadvisory.amd.com - a private subnet works
    only if it routes through a NAT gateway. A service gateway alone is not
    enough: CCA is not an OCI service endpoint.
  EOT
}

variable "cca_secret_ocid" {
  type        = string
  description = <<-EOT
    OCID of an EXISTING Vault secret holding the CCA JWT. Create it outside
    Terraform - the OCI secret API takes base64 content, so a token passed as a
    Terraform variable would land in state in plaintext:
      oci vault secret create-base64 --compartment-id <C> --vault-id <V> \
        --secret-name cca-api-key --key-id <KEY> \
        --secret-content-content "$(base64 -w0 cca_api_key.txt)"
  EOT
}

variable "schedule_cron" {
  type        = string
  default     = "0 7 * * 1"
  description = "Weekly, Mondays 07:00 UTC. Resource Scheduler evaluates cron in UTC."
}

variable "clouds" {
  type        = string
  default     = "AWS,AZURE,GCP,OCI"
  description = "Restrict the sweep. Leave all four unless you only care about one."
}

variable "notification_email" {
  type        = string
  default     = ""
  description = "Optional address subscribed to the change topic. Empty creates the topic but no subscription."
}

variable "insecure_tls" {
  type        = bool
  default     = false
  description = "Set true only behind a TLS-intercepting proxy."
}

variable "function_memory_mb" {
  type    = number
  default = 1024
}

locals {
  subscribe = var.notification_email == "" ? 0 : 1
  fn_name   = "${var.name_prefix}-weekly"
}

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_ocid
}

# ------------------------------------------------------------------ artifacts

resource "oci_objectstorage_bucket" "artifacts" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "${var.name_prefix}-artifacts"

  access_type = "NoPublicAccess"

  # The bucket is the audit trail of what each week's policy looked like.
  versioning = "Enabled"
}

# --------------------------------------------------------------- notification

resource "oci_ons_notification_topic" "changes" {
  compartment_id = var.compartment_ocid
  name           = "${var.name_prefix}-changes"
  description    = "AMD IAM policy changes and failures"
}

resource "oci_ons_subscription" "email" {
  count          = local.subscribe
  compartment_id = var.compartment_ocid
  topic_id       = oci_ons_notification_topic.changes.id
  protocol       = "EMAIL"
  endpoint       = var.notification_email
}

# ------------------------------------------------------------------- function

resource "oci_functions_application" "this" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}-app"
  subnet_ids     = [var.subnet_ocid]

  # Fn surfaces application config as environment variables, which is where
  # ../func.py reads them from - the same names the Lambda handler uses.
  # The token is NOT here - it is fetched from Vault at run time using the
  # function's resource principal, so it never sits in a config map.
  config = {
    ARTIFACT_BUCKET = oci_objectstorage_bucket.artifacts.name
    ARTIFACT_PREFIX = var.name_prefix
    OCI_NAMESPACE   = data.oci_objectstorage_namespace.this.namespace
    CCA_SECRET_ID   = var.cca_secret_ocid
    NOTIFY_TOPIC_ID = oci_ons_notification_topic.changes.id
    CLOUDS          = var.clouds
    INSECURE_TLS    = var.insecure_tls ? "true" : "false"
  }
}

resource "oci_functions_function" "weekly" {
  application_id = oci_functions_application.this.id
  display_name   = local.fn_name
  image          = var.container_image
  memory_in_mbs  = var.function_memory_mb

  # A full four-cloud sweep measured ~48s, nearly all of it waiting on CCA.
  # 300s is the OCI Functions maximum, so unlike the other three clouds there
  # is no room to go higher - which is the reason --cloud exists. If CCA ever
  # slows to the point of timing out, split the sweep across several
  # single-cloud schedules rather than trying to raise this.
  timeout_in_seconds = 300
}

# ----------------------------------------------------------- resource principal
#
# The function authenticates as itself. These grants are what
# oci.auth.signers.get_resource_principals_signer() in runner.py resolves to.

resource "oci_identity_dynamic_group" "fn" {
  compartment_id = var.tenancy_ocid
  name           = "${var.name_prefix}-fn-dg"
  description    = "The weekly AMD policy generator function"
  matching_rule  = "ALL {resource.type = 'fnfunc', resource.compartment.id = '${var.compartment_ocid}'}"
}

resource "oci_identity_policy" "fn" {
  compartment_id = var.tenancy_ocid
  name           = "${var.name_prefix}-fn-policy"
  description    = "Least privilege for the weekly AMD policy generator"

  # Scoped to the one bucket, the one secret and the one topic. Note
  # manage objects rather than read: the job reads last week's artifacts to
  # diff against and writes this week's.
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.fn.name} to manage objects in compartment id ${var.compartment_ocid} where target.bucket.name = '${oci_objectstorage_bucket.artifacts.name}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.fn.name} to read buckets in compartment id ${var.compartment_ocid} where target.bucket.name = '${oci_objectstorage_bucket.artifacts.name}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.fn.name} to read secret-bundles in compartment id ${var.compartment_ocid} where target.secret.id = '${var.cca_secret_ocid}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.fn.name} to use ons-topics in compartment id ${var.compartment_ocid} where target.topic.id = '${oci_ons_notification_topic.changes.id}'",
  ]
}

# ------------------------------------------------------------------- schedule
#
# Resource Scheduler acts as a resource principal of its own, so it needs its
# own dynamic group - separate from the function's, so "may trigger the job"
# and "may read the CCA token" remain separate grants.
#
# The action is START_RESOURCE, not "invoke". Resource Scheduler's action enum
# is START_RESOURCE / STOP_RESOURCE / BACKUP_RESOURCE - it models a function
# the same way it models a stoppable VM, and starting a function invokes it.
#
# Before applying, confirm functions are schedulable in your tenancy:
#   oci resource-scheduler resource-type-collection list-resource-types
# Oracle documents compute and autonomous DB explicitly and publishes a
# separate "Scheduling a Function" guide, but the authoritative per-tenancy
# answer is that call. If functions are not listed, see the README for the
# OCI Events + Notifications fallback.

resource "oci_identity_dynamic_group" "scheduler" {
  compartment_id = var.tenancy_ocid
  name           = "${var.name_prefix}-sched-dg"
  description    = "Resource Scheduler schedules that trigger the AMD policy generator"
  matching_rule  = "ALL {resource.type = 'resourceschedule', resource.compartment.id = '${var.compartment_ocid}'}"
}

resource "oci_identity_policy" "scheduler" {
  compartment_id = var.tenancy_ocid
  name           = "${var.name_prefix}-sched-policy"
  description    = "Lets Resource Scheduler invoke the weekly function"

  # Oracle documents manage functions-family for this; it is the grant the
  # service checks before issuing the START. It cannot read the secret or the
  # bucket, so a compromise of the trigger does not yield the credential.
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.scheduler.name} to manage functions-family in compartment id ${var.compartment_ocid}",
  ]
}

resource "oci_resource_scheduler_schedule" "weekly" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}-weekly"
  description    = "Weekly AMD CCA policy regeneration"

  action             = "START_RESOURCE"
  recurrence_type    = "CRON"
  recurrence_details = var.schedule_cron

  resources {
    id = oci_functions_function.weekly.id
  }

  depends_on = [oci_identity_policy.scheduler]
}

# -------------------------------------------------------------------- outputs

output "function_ocid" {
  value = oci_functions_function.weekly.id
}

output "artifact_bucket" {
  description = "Where generated policies land (current/ and history/<date>/)"
  value       = oci_objectstorage_bucket.artifacts.name
}

output "namespace" {
  value = data.oci_objectstorage_namespace.this.namespace
}

output "topic_ocid" {
  value = oci_ons_notification_topic.changes.id
}

output "manual_run" {
  description = "Run it now instead of waiting for Monday"
  value       = "oci fn function invoke --function-id ${oci_functions_function.weekly.id} --file - --body ''"
}

output "read_results" {
  value = "oci os object list -bn ${oci_objectstorage_bucket.artifacts.name} --prefix ${var.name_prefix}/current/"
}
