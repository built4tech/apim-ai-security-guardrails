// ─────────────────────────────────────────────────────────────────────────────
// Módulo: Azure Monitor Workbook (AI Security)
// Despliega el workbook de análisis de seguridad (analytics/workbook-ai-security.json)
// apuntando al workspace de Log Analytics como scope por defecto.
// ─────────────────────────────────────────────────────────────────────────────

@description('Ubicación del recurso.')
param location string

@description('Resource ID del workspace de Log Analytics usado como scope del workbook.')
param workspaceId string

@description('Nombre visible del workbook.')
param displayName string = 'AI Security - GitHub Models (APIM + Content Safety)'

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'ai-security-workbook')
  location: location
  kind: 'shared'
  properties: {
    displayName: displayName
    category: 'workbook'
    sourceId: workspaceId
    serializedData: loadTextContent('../../analytics/workbook-ai-security.json')
  }
}

@description('Resource ID del workbook.')
output id string = workbook.id
