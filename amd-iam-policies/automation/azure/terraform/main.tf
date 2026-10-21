###############################################################################
# Weekly AMD IAM policy regeneration - Azure, Terraform alternative.
#
# Same shape as ../main.bicep: a Container Apps Job on a weekly cron, CCA token
# in Key Vault read via managed identity, artifacts versioned in blob storage,
# alerts only when a policy really changed or the run failed. Pick one or the
# other - running both creates two of everything.
#
#   terraform init
#   terraform apply \
#     -var container_image=myacr.azurecr.io/amd-iam-policies:2026-10-21 \
#     -var cca_key_vault_name=my-vault \
#     -var cca_key_vault_resource_group=my-vault-rg \
#     -var notification_email=you@example.com
#
# The image is built from ../../Dockerfile with CLOUD=azure, from the repo root:
#   docker build -f automation/Dockerfile --build-arg CLOUD=azure -t <img> .
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # 4.11 is the floor, not 4.0: azurerm_storage_container.storage_account_id
      # was added part-way through the 4.x line, and on anything older this
      # config fails with "unsupported argument".
      version = ">= 4.11"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

provider "azurerm" {
  features {}

  # The storage account below disables shared keys, so Terraform's own
  # data-plane calls (creating the container) must authenticate as the signed-in
  # principal instead. Without this the apply fails with KeyBasedAuthenticationNotPermitted.
  storage_use_azuread = true
}

# ------------------------------------------------------------------ variables

variable "location" {
  type        = string
  default     = "eastus"
  description = "Region for the automation itself. Unrelated to which cloud regions the policies cover - the CCA sweep is global either way."
}

variable "name_prefix" {
  type    = string
  default = "amd-iam-policies"
}

variable "container_image" {
  type        = string
  description = "Image built from automation/Dockerfile with CLOUD=azure. Tag with a date, not :latest - a scheduled job that silently picks up a new :latest is a policy generator you no longer control."
}

variable "cca_key_vault_name" {
  type        = string
  description = <<-EOT
    Name of an EXISTING Key Vault holding the CCA JWT. Create the secret
    outside Terraform:
      az keyvault secret set --vault-name <VAULT> -n cca-api-key \
        --file cca_api_key.txt
    Passing the token as a Terraform variable would write it to state in
    plaintext, which is why this takes a vault name and not the token.
    The vault must use Azure RBAC (enableRbacAuthorization), not access policies.
  EOT
}

variable "cca_key_vault_resource_group" {
  type        = string
  description = "Resource group containing that vault. May differ from the one created here."
}

variable "cca_secret_name" {
  type    = string
  default = "cca-api-key"
}

variable "cron_expression" {
  type        = string
  default     = "0 7 * * 1"
  description = "Weekly, Mondays 07:00. Container Apps evaluates cron in UTC."
}

variable "clouds" {
  type        = string
  default     = "AWS,AZURE,GCP,OCI"
  description = "Restrict the sweep. Leave all four unless you only care about one."
}

variable "notification_email" {
  type        = string
  default     = ""
  description = "Optional address for change and failure alerts. Empty disables both."
}

variable "insecure_tls" {
  type        = bool
  default     = false
  description = "Set true only behind a TLS-intercepting proxy."
}

variable "log_retention_days" {
  type    = number
  default = 90
}

locals {
  alerts_on = var.notification_email == "" ? 0 : 1
  job_name  = "${var.name_prefix}-weekly"
  container = "policies"

  # Storage account names are 3-24 lowercase alphanumerics, globally unique.
  storage_name = substr("${replace(var.name_prefix, "-", "")}${random_string.suffix.result}", 0, 24)

  args = concat(
    [
      "--backend", "azure",
      "--account", azurerm_storage_account.artifacts.name,
      "--container", local.container,
      "--prefix", var.name_prefix,
      "--secret", "${data.azurerm_key_vault.cca.vault_uri}|${var.cca_secret_name}",
      "--cloud", var.clouds,
    ],
    var.insecure_tls ? ["--insecure"] : []
  )
}

resource "random_string" "suffix" {
  length  = 8
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_resource_group" "this" {
  name     = "${var.name_prefix}-rg"
  location = var.location
}

# ------------------------------------------------------------------- identity

resource "azurerm_user_assigned_identity" "runner" {
  name                = "${var.name_prefix}-identity"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

data "azurerm_key_vault" "cca" {
  name                = var.cca_key_vault_name
  resource_group_name = var.cca_key_vault_resource_group
}

# Key Vault Secrets User: get/list on secret VALUES only - not set, not
# delete, no management-plane operation.
resource "azurerm_role_assignment" "vault" {
  scope                = data.azurerm_key_vault.cca.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.runner.principal_id
}

# -------------------------------------------------------------------- storage

resource "azurerm_storage_account" "artifacts" {
  name                     = local.storage_name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  # The job authenticates with its managed identity, so a leaked account key
  # is not a thing that can exist.
  shared_access_key_enabled = false

  blob_properties {
    # The container is the audit trail of what each week's policy looked like.
    versioning_enabled = true
    delete_retention_policy {
      days = 365
    }
  }
}

resource "azurerm_storage_container" "policies" {
  name                  = local.container
  storage_account_id    = azurerm_storage_account.artifacts.id
  container_access_type = "private"
}

# Storage Blob Data Contributor - the job reads last week's artifacts to diff
# against and writes this week's, so read-only is not enough.
resource "azurerm_role_assignment" "storage" {
  scope                = azurerm_storage_account.artifacts.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.runner.principal_id
}

# -------------------------------------------------------------- observability

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.name_prefix}-logs"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
}

resource "azurerm_container_app_environment" "this" {
  name                       = "${var.name_prefix}-env"
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
}

# ------------------------------------------------------------------------ job
#
# No secret block on the job. runner.py --backend azure reads the token
# straight out of Key Vault with DefaultAzureCredential, so all the job needs
# is the vault URI, the secret name and the role assignment above. Wiring a
# Container Apps Key Vault secret reference as well would resolve the same
# value a second time into the container's environment - strictly more
# exposure for no gain.

resource "azurerm_container_app_job" "weekly" {
  name                         = local.job_name
  location                     = azurerm_resource_group.this.location
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id

  # A full four-cloud sweep measured ~48s, nearly all of it waiting on CCA.
  # 900s absorbs a slow CCA day without letting a hung call run on.
  replica_timeout_in_seconds = 900
  replica_retry_limit        = 2

  schedule_trigger_config {
    cron_expression          = var.cron_expression
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.runner.id]
  }

  template {
    container {
      name   = "generate"
      image  = var.container_image
      cpu    = 0.5
      memory = "1Gi"
      args   = local.args

      env {
        # DefaultAzureCredential needs the client id to pick the right
        # identity when a user-assigned one is attached.
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.runner.client_id
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.vault,
    azurerm_role_assignment.storage,
    azurerm_storage_container.policies,
  ]
}

# ------------------------------------------------------------------- alerting
#
# Two alerts, because on Azure they carry different news.
#
# runner.py publishes change reports through SNS on AWS, Pub/Sub on GCP and
# ONS on OCI. It has no Azure notifier, so on Azure the report goes to stdout
# and lands in Log Analytics - which makes the change alert below the thing
# that actually delivers it. Without it, Azure would be the one cloud where a
# policy change is silent.

resource "azurerm_monitor_action_group" "alerts" {
  count               = local.alerts_on
  name                = "${var.name_prefix}-alerts"
  resource_group_name = azurerm_resource_group.this.name
  short_name          = substr(replace(var.name_prefix, "-", ""), 0, 12)

  email_receiver {
    name                    = "owner"
    email_address           = var.notification_email
    use_common_alert_schema = true
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "failed" {
  count               = local.alerts_on
  name                = "${var.name_prefix}-job-failed"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  description         = "The weekly CCA sweep raised an error. The previously generated policies in blob storage are unchanged and still valid."
  severity            = 2
  enabled             = true
  scopes              = [azurerm_log_analytics_workspace.this.id]

  # Hourly evaluation over a 1-day window: the job runs weekly, so this
  # reports a Monday failure within the hour.
  evaluation_frequency = "PT1H"
  window_duration      = "P1D"

  criteria {
    query                   = <<-KQL
      ContainerAppConsoleLogs_CL
      | where Log_s has "FAILED:" or Log_s has "Traceback (most recent call last)"
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.alerts[0].id]
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "changed" {
  count               = local.alerts_on
  name                = "${var.name_prefix}-policy-changed"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  description         = "CCA now answers differently for at least one region/family. Review the diff in the job log, then re-upload the changed artifacts as described in each cloud README."
  severity            = 3
  enabled             = true
  scopes              = [azurerm_log_analytics_workspace.this.id]

  evaluation_frequency = "PT1H"
  window_duration      = "P1D"

  criteria {
    # The exact banner runner.py prints when, and only when, a policy artifact
    # differs from the stored copy.
    query                   = <<-KQL
      ContainerAppConsoleLogs_CL
      | where Log_s has "AMD IAM policies changed"
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.alerts[0].id]
  }
}

# -------------------------------------------------------------------- outputs

output "job_name" {
  value = azurerm_container_app_job.weekly.name
}

output "storage_account" {
  description = "Where generated policies land (current/ and history/<date>/)"
  value       = azurerm_storage_account.artifacts.name
}

output "blob_container" {
  value = azurerm_storage_container.policies.name
}

output "identity_principal_id" {
  value = azurerm_user_assigned_identity.runner.principal_id
}

output "manual_run" {
  description = "Run it now instead of waiting for Monday"
  value       = "az containerapp job start -n ${azurerm_container_app_job.weekly.name} -g ${azurerm_resource_group.this.name}"
}

output "read_results" {
  value = "az storage blob list --account-name ${azurerm_storage_account.artifacts.name} -c ${azurerm_storage_container.policies.name} --prefix ${var.name_prefix}/current --auth-mode login -o table"
}
