// ─────────────────────────────────────────────────────────────────────────────
// Módulo: Log Analytics Workspace + Application Insights
// Destino de los GatewayLogs de APIM (tabla ApiManagementGatewayLogs) para las
// queries KQL y el Workbook de seguridad.
// ─────────────────────────────────────────────────────────────────────────────

@description('Nombre del workspace de Log Analytics.')
param workspaceName string

@description('Nombre del recurso Application Insights.')
param appInsightsName string

@description('Ubicación de los recursos.')
param location string

@description('Días de retención de logs.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

@description('Resource ID del workspace de Log Analytics.')
output workspaceId string = workspace.id

@description('Nombre del workspace de Log Analytics.')
output workspaceName string = workspace.name

@description('Resource ID de Application Insights.')
output appInsightsId string = appInsights.id

@description('Instrumentation Key de Application Insights.')
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey
