// Grants the runner identity read access to the CCA secret.
//
// This is a separate module purely because of an ARM scoping rule: a role
// assignment on a resource in another resource group cannot be declared from a
// resource-group deployment directly - it has to go through a nested
// deployment targeted at the group that owns the resource. main.bicep calls
// this with `scope: resourceGroup(ccaKeyVaultResourceGroup)`, so the same code
// works whether the vault is local or owned by a central team elsewhere in the
// subscription.

@description('Name of the existing Key Vault, in THIS module\'s resource group.')
param keyVaultName string

@description('Principal id of the user-assigned identity that runs the job.')
param principalId string

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// Key Vault Secrets User: get/list on secret VALUES and nothing else - not
// set, not delete, no management-plane operation.
//
// This requires the vault to use Azure RBAC (enableRbacAuthorization). On a
// vault still using access policies the assignment deploys cleanly but has no
// effect, and the job fails at run time with a 403 - so check that first if
// the very first execution cannot read the token.
var secretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource vaultAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, principalId, secretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsUserRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

@description('Vault URI, passed back so main.bicep does not need its own reference to a vault it may not be able to scope to.')
output vaultUri string = vault.properties.vaultUri
