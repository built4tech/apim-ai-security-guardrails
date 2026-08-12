// ─────────────────────────────────────────────────────────────────────────────
// Módulo: Azure AI Content Safety
// Cuenta Cognitive Services (kind ContentSafety) que provee tanto el análisis de
// toxicidad (text:analyze) como Prompt Shield (text:shieldPrompt).
// Se habilita customSubDomainName para permitir autenticación con Managed Identity
// (token AAD) desde las políticas de APIM.
// ─────────────────────────────────────────────────────────────────────────────

@description('Nombre de la cuenta de Content Safety.')
param name string

@description('Ubicación del recurso.')
param location string

@description('SKU de Content Safety. F0 (free) está limitado a 1 por suscripción; S0 recomendado para portabilidad.')
@allowed([
  'F0'
  'S0'
])
param sku string = 'S0'

@description('Deshabilitar autenticación con clave local (fuerza el uso de Managed Identity / AAD).')
param disableLocalAuth bool = true

resource contentSafety 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: name
  location: location
  kind: 'ContentSafety'
  sku: {
    name: sku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    // Necesario para que el endpoint acepte tokens AAD (Managed Identity de APIM)
    customSubDomainName: name
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: disableLocalAuth
  }
}

@description('Resource ID de la cuenta de Content Safety.')
output id string = contentSafety.id

@description('Nombre de la cuenta de Content Safety.')
output name string = contentSafety.name

@description('Endpoint base del recurso (termina en "/").')
output endpoint string = contentSafety.properties.endpoint
