// ─────────────────────────────────────────────────────────────────────────────
// Módulo: RBAC
// Concede a la Managed Identity de APIM los permisos necesarios:
//   - Cognitive Services User  → invocar Content Safety / Prompt Shield
//   - Key Vault Secrets User   → leer el secreto del token de GitHub
// ─────────────────────────────────────────────────────────────────────────────

@description('Principal ID de la Managed Identity de APIM.')
param apimPrincipalId string

@description('Nombre de la cuenta de Content Safety (para scope del role assignment).')
param contentSafetyName string

@description('Nombre del Key Vault (para scope del role assignment).')
param keyVaultName string

// Role Definition IDs (built-in)
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource contentSafety 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: contentSafetyName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource cognitiveServicesUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(contentSafety.id, apimPrincipalId, cognitiveServicesUserRoleId)
  scope: contentSafety
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource keyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, apimPrincipalId, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}
