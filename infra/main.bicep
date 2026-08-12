// ═════════════════════════════════════════════════════════════════════════════
// GitHub Models + Azure Content Safety / Prompt Shield — Plantilla de despliegue
// ─────────────────────────────────────────────────────────────────────────────
// Despliega el entorno completo de la PoC de forma reproducible y portable:
//   - Log Analytics + Application Insights
//   - Azure AI Content Safety (toxicidad + Prompt Shield)
//   - Key Vault con el token del proveedor de modelo (único secreto)
//   - API Management (identidad gestionada) con la API "github-redirection"
//     y sus 4 operaciones/políticas (proxy, +CS, +PS, +CS&PS)
//   - RBAC: APIM → Cognitive Services User (CS) y Key Vault Secrets User (KV)
//   - Diagnósticos de APIM → Log Analytics (GatewayLogs)
//   - Workbook de seguridad de IA
//
// Scope: Resource Group
// ═════════════════════════════════════════════════════════════════════════════

targetScope = 'resourceGroup'

// ─── Parámetros generales ────────────────────────────────────────────────────

@description('Ubicación de todos los recursos. Por defecto, la del Resource Group.')
param location string = resourceGroup().location

@description('Prefijo corto para nombrar los recursos (minúsculas y números).')
@minLength(3)
@maxLength(12)
param namePrefix string = 'aisec'

@description('Sufijo único para nombres globalmente únicos. Por defecto derivado del Resource Group.')
param nameSuffix string = take(uniqueString(resourceGroup().id), 6)

// ─── Parámetros APIM ─────────────────────────────────────────────────────────

@description('Email del publicador de APIM.')
param apimPublisherEmail string

@description('Nombre del publicador de APIM.')
param apimPublisherName string

@description('SKU de APIM.')
@allowed([
  'Developer'
  'Basic'
  'Standard'
  'Premium'
  'BasicV2'
  'StandardV2'
])
param apimSkuName string = 'Developer'

@description('Capacidad (unidades) del SKU de APIM.')
@minValue(1)
param apimCapacity int = 1

// ─── Parámetros Content Safety ───────────────────────────────────────────────

@description('SKU de Content Safety (F0 limitado a 1 por suscripción).')
@allowed([
  'F0'
  'S0'
])
param contentSafetySku string = 'S0'

// ─── Parámetros Key Vault / secreto ──────────────────────────────────────────

@description('Token de la API del proveedor de modelo (p.ej. Groq). Parámetro seguro; se guarda en Key Vault.')
@secure()
param modelApiToken string

// ─── Parámetros Log Analytics ────────────────────────────────────────────────

@description('Días de retención de logs.')
@minValue(30)
@maxValue(730)
param logRetentionInDays int = 30

// ─── Nombres derivados ───────────────────────────────────────────────────────

var apimName = '${namePrefix}-apim-${nameSuffix}'
var contentSafetyName = '${namePrefix}-cs-${nameSuffix}'
var keyVaultName = take('${namePrefix}kv${nameSuffix}', 24)
var workspaceName = '${namePrefix}-law-${nameSuffix}'
var appInsightsName = '${namePrefix}-appi-${nameSuffix}'

// ─── Log Analytics + Application Insights ────────────────────────────────────

module monitoring 'modules/loganalytics.bicep' = {
  name: 'loganalytics'
  params: {
    workspaceName: workspaceName
    appInsightsName: appInsightsName
    location: location
    retentionInDays: logRetentionInDays
  }
}

// ─── Content Safety ──────────────────────────────────────────────────────────

module contentSafety 'modules/contentsafety.bicep' = {
  name: 'contentsafety'
  params: {
    name: contentSafetyName
    location: location
    sku: contentSafetySku
  }
}

// ─── Key Vault ───────────────────────────────────────────────────────────────

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    name: keyVaultName
    location: location
    modelApiToken: modelApiToken
  }
}

// ─── API Management ──────────────────────────────────────────────────────────

module apim 'modules/apim.bicep' = {
  name: 'apim'
  params: {
    name: apimName
    location: location
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    skuName: apimSkuName
    capacity: apimCapacity
  }
}

// ─── RBAC (debe existir antes de crear el Named Value con KV reference) ───────

module rbac 'modules/rbac.bicep' = {
  name: 'rbac'
  params: {
    apimPrincipalId: apim.outputs.principalId
    contentSafetyName: contentSafety.outputs.name
    keyVaultName: keyVault.outputs.name
  }
}

// ─── API + Named Values + Operaciones + Políticas ────────────────────────────

module apis 'modules/apim-apis.bicep' = {
  name: 'apim-apis'
  params: {
    apimName: apim.outputs.name
    modelApiTokenSecretUri: keyVault.outputs.modelApiTokenSecretUri
    contentSafetyEndpoint: contentSafety.outputs.endpoint
  }
  dependsOn: [
    rbac
  ]
}

// ─── Diagnósticos de APIM → Log Analytics ────────────────────────────────────

module diagnostics 'modules/diagnostics.bicep' = {
  name: 'diagnostics'
  params: {
    apimName: apim.outputs.name
    workspaceId: monitoring.outputs.workspaceId
  }
}

// ─── APIM → Application Insights (logger + diagnostic) ────────────────────────

module apimAppInsights 'modules/apim-appinsights.bicep' = {
  name: 'apim-appinsights'
  params: {
    apimName: apim.outputs.name
    appInsightsId: monitoring.outputs.appInsightsId
    appInsightsInstrumentationKey: monitoring.outputs.appInsightsInstrumentationKey
  }
  dependsOn: [
    apis
  ]
}

// ─── Workbook de seguridad ───────────────────────────────────────────────────

module workbook 'modules/monitoring.bicep' = {
  name: 'workbook'
  params: {
    location: location
    workspaceId: monitoring.outputs.workspaceId
  }
}

// ─── Salidas ─────────────────────────────────────────────────────────────────

@description('Nombre del servicio APIM.')
output apimName string = apim.outputs.name

@description('URL del gateway de APIM.')
output apimGatewayUrl string = apim.outputs.gatewayUrl

@description('Endpoints de las 4 operaciones (añadir a environment.env).')
output endpoints object = {
  direct: '${apim.outputs.gatewayUrl}/gh-redirect'
  contentSafety: '${apim.outputs.gatewayUrl}/gh-cs-redirect'
  promptShield: '${apim.outputs.gatewayUrl}/gh-ps-redirect'
  contentSafetyAndPromptShield: '${apim.outputs.gatewayUrl}/gh-cs-ps-redirect'
}

@description('Endpoint de Content Safety.')
output contentSafetyEndpoint string = contentSafety.outputs.endpoint

@description('Nombre de la cuenta de Content Safety.')
output contentSafetyName string = contentSafety.outputs.name

@description('Nombre del Key Vault.')
output keyVaultName string = keyVault.outputs.name

@description('Principal ID de la Managed Identity de APIM.')
output apimPrincipalId string = apim.outputs.principalId

@description('Nombre del workspace de Log Analytics.')
output logAnalyticsWorkspace string = monitoring.outputs.workspaceName
