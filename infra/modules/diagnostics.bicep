// ─────────────────────────────────────────────────────────────────────────────
// Módulo: Diagnostic Settings de APIM → Log Analytics
// Envía los GatewayLogs (tabla ApiManagementGatewayLogs) al workspace para las
// queries KQL y el Workbook. Reproduce el diagnostic setting "default" del
// entorno real (GatewayLogs + WebSocketConnectionLogs).
// ─────────────────────────────────────────────────────────────────────────────

@description('Nombre del servicio APIM existente.')
param apimName string

@description('Resource ID del workspace de Log Analytics destino.')
param workspaceId string

@description('Nombre del diagnostic setting.')
param settingName string = 'default'

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' existing = {
  name: apimName
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: settingName
  scope: apim
  properties: {
    workspaceId: workspaceId
    // 'Dedicated' → los logs caen en la tabla resource-specific
    // `ApiManagementGatewayLogs` (la que consultan las KQL y el Workbook).
    // Sin esto, Azure usa por defecto la tabla legacy `AzureDiagnostics`.
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'GatewayLogs'
        enabled: true
      }
      {
        category: 'WebSocketConnectionLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}
