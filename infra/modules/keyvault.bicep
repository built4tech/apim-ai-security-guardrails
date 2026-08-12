// ─────────────────────────────────────────────────────────────────────────────
// Módulo: Azure Key Vault + secreto del token del proveedor de modelo
// El token de la API del proveedor de modelo (p.ej. Groq) es el único secreto real
// de la solución. Se almacena aquí y APIM lo referencia como Named Value vía Key
// Vault reference (con su Managed Identity y el rol "Key Vault Secrets User").
// ─────────────────────────────────────────────────────────────────────────────

@description('Nombre del Key Vault (3-24 caracteres, único global).')
param name string

@description('Ubicación del recurso.')
param location string

@description('Nombre del secreto que contiene el token de la API del modelo.')
param modelApiTokenSecretName string = 'model-api-token'

@description('Valor del token de la API del proveedor de modelo (parámetro seguro).')
@secure()
param modelApiToken string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    // RBAC en lugar de access policies: necesario para conceder acceso a la MI de APIM
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

resource modelApiTokenSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: modelApiTokenSecretName
  properties: {
    value: modelApiToken
    contentType: 'Model provider API token'
  }
}

@description('Resource ID del Key Vault.')
output id string = keyVault.id

@description('Nombre del Key Vault.')
output name string = keyVault.name

@description('Identificador del secreto sin versión (para que APIM refresque automáticamente).')
output modelApiTokenSecretUri string = modelApiTokenSecret.properties.secretUri
