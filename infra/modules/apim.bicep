// ─────────────────────────────────────────────────────────────────────────────
// Módulo: Azure API Management
// Servicio APIM con identidad SystemAssigned (usada para autenticarse contra
// Content Safety y Key Vault sin claves).
// ─────────────────────────────────────────────────────────────────────────────

@description('Nombre del servicio APIM (único global).')
param name string

@description('Ubicación del recurso.')
param location string

@description('Email del publicador.')
param publisherEmail string

@description('Nombre del publicador.')
param publisherName string

@description('SKU de APIM.')
@allowed([
  'Developer'
  'Basic'
  'Standard'
  'Premium'
  'BasicV2'
  'StandardV2'
])
param skuName string = 'Developer'

@description('Capacidad (unidades) del SKU.')
@minValue(1)
param capacity int = 1

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: name
  location: location
  sku: {
    name: skuName
    capacity: capacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

@description('Resource ID de APIM.')
output id string = apim.id

@description('Nombre del servicio APIM.')
output name string = apim.name

@description('Principal ID de la Managed Identity de APIM.')
output principalId string = apim.identity.principalId

@description('URL del gateway de APIM.')
output gatewayUrl string = apim.properties.gatewayUrl
