// Weekly AMD IAM policy regeneration - Azure, native IaC (Bicep/ARM).
//
// Container Apps Job on a cron trigger. The CCA token stays in Key Vault and
// is read at run time by a user-assigned managed identity, so the token is
// never in this template, never a deployment parameter, and never in the image.
//
//   az deployment group create -g <RG> -f main.bicep \
//     -p containerImage=myacr.azurecr.io/amd-iam-policies:2026-10-21 \
//        ccaKeyVaultName=<VAULT> notificationEmail=you@example.com
//
// Why a Container Apps Job and not an Azure Function: the work is one ~48s
// batch run on a timer with no HTTP surface. A job models that directly,
// scales to zero between runs, and consumes the same container image GCP and
// OCI use. A timer-triggered Function would also work but needs its own
// deployment format and a storage account for the trigger's own bookkeeping.

targetScope = 'resourceGroup'

@description('Prefix for created resources.')
@minLength(3)
@maxLength(24)
param namePrefix string = 'amd-iam-policies'

@description('Location. Defaults to the resource group.')
param location string = resourceGroup().location

@description('Container image built from automation/Dockerfile with CLOUD=azure.')
param containerImage string

@description('Name of an EXISTING Key Vault holding the CCA token. Create the secret outside this template so its value is never a deployment parameter - parameters are recorded in the deployment history.')
param ccaKeyVaultName string

@description('Resource group containing that vault. Defaults to this deployment\'s resource group; set it if the vault lives elsewhere, which is common when a central team owns the vault.')
param ccaKeyVaultResourceGroup string = resourceGroup().name

@description('Secret name within that vault.')
param ccaSecretName string = 'cca-api-key'

@description('Weekly, Mondays 07:00. Container Apps evaluates cron in UTC.')
param cronExpression string = '0 7 * * 1'

@description('Restrict the sweep. Leave all four unless you only care about one.')
param clouds string = 'AWS,AZURE,GCP,OCI'

@description('Optional address for change and failure notifications. Empty disables both alerts.')
param notificationEmail string = ''

@description('Set true only behind a TLS-intercepting proxy.')
param insecureTls bool = false

var storageName = toLower(take(replace('${namePrefix}${uniqueString(resourceGroup().id)}', '-', ''), 24))
var jobName = '${namePrefix}-weekly'
var blobContainerName = 'policies'
var alertsOn = !empty(notificationEmail)

// ---------------------------------------------------------------- identity

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-identity'
  location: location
}

// The vault may live in another resource group, so both the role assignment
// and the vault lookup go through a nested deployment targeted at that group.
// See vault-access.bicep for why ARM requires this.
module vaultAccess 'vault-access.bicep' = {
  name: 'cca-vault-access'
  scope: resourceGroup(ccaKeyVaultResourceGroup)
  params: {
    keyVaultName: ccaKeyVaultName
    principalId: identity.properties.principalId
  }
}

// ----------------------------------------------------------------- storage

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    // The job authenticates with its managed identity. Disabling shared keys
    // means a leaked account key is not a thing that can exist.
    allowSharedKeyAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    // The container is the audit trail of what each week's policy looked like.
    isVersioningEnabled: true
    deleteRetentionPolicy: {
      enabled: true
      days: 365
    }
  }
}

resource policyContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: blobContainerName
  properties: {
    publicAccess: 'None'
  }
}

// Storage Blob Data Contributor - the job reads last week's artifacts to diff
// against and writes this week's, so read-only is not enough.
var blobContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource storageAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, identity.id, blobContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobContributorRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ------------------------------------------------------------- observability

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-logs'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 90
  }
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${namePrefix}-env'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

// --------------------------------------------------------------------- job
//
// No `secrets` block here on purpose. runner.py --backend azure reads the
// token straight out of Key Vault with DefaultAzureCredential, so the only
// thing the job needs is the vault URI, the secret name, and the role
// assignment above. Wiring a Container Apps Key Vault secret reference as
// well would resolve the same value a second time and place it in the
// container's environment, which is strictly more exposure for no gain.

resource job 'Microsoft.App/jobs@2024-03-01' = {
  name: jobName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    environmentId: env.id
    configuration: {
      triggerType: 'Schedule'
      scheduleTriggerConfig: {
        cronExpression: cronExpression
        parallelism: 1
        replicaCompletionCount: 1
      }
      // A full four-cloud sweep measured ~48s, nearly all of it waiting on
      // CCA. 900s absorbs a slow CCA day without letting a hung call run on.
      replicaTimeout: 900
      replicaRetryLimit: 2
    }
    template: {
      containers: [
        {
          name: 'generate'
          image: containerImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          args: concat([
            '--backend'
            'azure'
            '--account'
            storage.name
            '--container'
            blobContainerName
            '--prefix'
            namePrefix
            '--secret'
            '${vaultAccess.outputs.vaultUri}|${ccaSecretName}'
            '--cloud'
            clouds
          ], insecureTls ? ['--insecure'] : [])
          env: [
            {
              // DefaultAzureCredential needs the client id to pick the right
              // identity when a user-assigned one is attached.
              name: 'AZURE_CLIENT_ID'
              value: identity.properties.clientId
            }
          ]
        }
      ]
    }
  }
  // The vault module is already an implicit dependency via the args
  // interpolation above. These two are not referenced anywhere in this
  // resource, so without declaring them the job could be created - and on a
  // Schedule trigger, fire - before its identity can write to the container.
  dependsOn: [
    storageAccess
    policyContainer
  ]
}

// -------------------------------------------------------------- alerting
//
// Two alerts, because on Azure they carry different news.
//
// runner.py publishes change reports through SNS on AWS, Pub/Sub on GCP and
// ONS on OCI. It has no Azure notifier, so on Azure the report goes to stdout
// and lands in Log Analytics - which means the change alert below is what
// actually delivers it. Without it the Azure deployment would be the one
// cloud where a policy change is silent.
//
// Both queries filter on log text alone rather than on a job-name column.
// This workspace is created by this template and holds only this job's logs,
// so a name filter would add a column-name dependency without narrowing
// anything.

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (alertsOn) {
  name: '${namePrefix}-alerts'
  location: 'global'
  properties: {
    groupShortName: take(replace(namePrefix, '-', ''), 12)
    enabled: true
    emailReceivers: [
      {
        name: 'owner'
        emailAddress: notificationEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

resource failureAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = if (alertsOn) {
  name: '${namePrefix}-job-failed'
  location: location
  properties: {
    displayName: 'AMD IAM policy regeneration failed'
    description: 'The weekly CCA sweep raised an error. The previously generated policies in blob storage are unchanged and still valid.'
    severity: 2
    enabled: true
    scopes: [
      logs.id
    ]
    // Hourly evaluation over a 1-day window: the job runs weekly, so this
    // reports a Monday failure within the hour and keeps reporting while the
    // failure is still inside the window.
    evaluationFrequency: 'PT1H'
    windowSize: 'P1D'
    criteria: {
      allOf: [
        {
          query: 'ContainerAppConsoleLogs_CL | where Log_s has "FAILED:" or Log_s has "Traceback (most recent call last)"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

resource changeAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = if (alertsOn) {
  name: '${namePrefix}-policy-changed'
  location: location
  properties: {
    displayName: 'AMD IAM policies changed'
    description: 'CCA now answers differently for at least one region/family. Review the diff in the job log, then re-upload the changed artifacts as described in each cloud README.'
    severity: 3
    enabled: true
    scopes: [
      logs.id
    ]
    evaluationFrequency: 'PT1H'
    windowSize: 'P1D'
    criteria: {
      allOf: [
        {
          // The exact banner _notify_log prints when, and only when, a policy
          // artifact differs from the stored copy.
          query: 'ContainerAppConsoleLogs_CL | where Log_s has "AMD IAM policies changed"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

output jobName string = job.name
output storageAccount string = storage.name
output blobContainer string = blobContainerName
output identityPrincipalId string = identity.properties.principalId
output logsWorkspace string = logs.name
output manualRun string = 'az containerapp job start -n ${job.name} -g ${resourceGroup().name}'
output readResults string = 'az storage blob list --account-name ${storage.name} -c ${blobContainerName} --prefix ${namePrefix}/current --auth-mode login -o table'
