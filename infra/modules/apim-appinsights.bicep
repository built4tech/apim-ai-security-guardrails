// ─────────────────────────────────────────────────────────────────────────────
// Módulo: APIM ↔ Application Insights (logger + diagnostic a nivel de APIM)
// Complementa a diagnostics.bicep (que envía GatewayLogs a Log Analytics):
// aquí conectamos APIM con Application Insights para telemetría de request/
// dependencias (vista APM clásica). Requiere un logger de tipo applicationInsights
// y un recurso service/diagnostics llamado 'applicationinsights' (en minúsculas).
// ─────────────────────────────────────────────────────────────────────────────

@description('Nombre del servicio APIM existente.')
param apimName string

@description('Resource ID del recurso Application Insights.')
param appInsightsId string

@description('Instrumentation Key de Application Insights.')
@secure()
param appInsightsInstrumentationKey string

@description('Porcentaje de muestreo (0-100). 100 = registrar todas las peticiones.')
@minValue(0)
@maxValue(100)
param samplingPercentage int = 100

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' existing = {
  name: apimName
}

// Logger de Application Insights a nivel de servicio APIM
resource apimLogger 'Microsoft.ApiManagement/service/loggers@2023-05-01-preview' = {
  parent: apim
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger para telemetría de APIM'
    resourceId: appInsightsId
    credentials: {
      instrumentationKey: appInsightsInstrumentationKey
    }
  }
}

// Diagnostic a nivel de servicio APIM que enruta la telemetría al logger.
// El nombre DEBE ser 'applicationinsights' (en minúsculas) para App Insights.
resource apimDiagnostic 'Microsoft.ApiManagement/service/diagnostics@2023-05-01-preview' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerId: apimLogger.id
    alwaysLog: 'allErrors'
    sampling: {
      samplingType: 'fixed'
      percentage: samplingPercentage
    }
    verbosity: 'information'
    httpCorrelationProtocol: 'W3C'
    logClientIp: true
    frontend: {
      request: {
        headers: []
        body: {
          bytes: 0
        }
      }
      response: {
        headers: []
        body: {
          bytes: 0
        }
      }
    }
    backend: {
      request: {
        headers: []
        body: {
          bytes: 0
        }
      }
      response: {
        headers: []
        body: {
          bytes: 0
        }
      }
    }
  }
}

@description('Resource ID del logger de Application Insights.')
output loggerId string = apimLogger.id

// ─────────────────────────────────────────────────────────────────────────────
// Diagnostic 'azuremonitor' → captura de cuerpo de respuesta en GatewayLogs.
// Sin este diagnostic, la columna `ResponseBody` de `ApiManagementGatewayLogs`
// llega VACÍA y las KQL/Workbook no pueden distinguir bloqueos de Content Safety
// vs Prompt Shield (dependen de `ResponseBody has "..."`).
// Requiere un logger de tipo azureMonitor (sin credenciales).
// ─────────────────────────────────────────────────────────────────────────────
@description('Bytes de cuerpo a registrar en GatewayLogs (máx 8192).')
@minValue(0)
@maxValue(8192)
param logBodyBytes int = 8192

resource apimAzMonLogger 'Microsoft.ApiManagement/service/loggers@2023-05-01-preview' = {
  parent: apim
  name: 'azuremonitor'
  properties: {
    loggerType: 'azureMonitor'
    description: 'Azure Monitor logger para captura de body en GatewayLogs'
  }
}

resource apimAzMonDiagnostic 'Microsoft.ApiManagement/service/diagnostics@2023-05-01-preview' = {
  parent: apim
  name: 'azuremonitor'
  properties: {
    loggerId: apimAzMonLogger.id
    alwaysLog: 'allErrors'
    sampling: {
      samplingType: 'fixed'
      percentage: samplingPercentage
    }
    verbosity: 'information'
    logClientIp: true
    frontend: {
      request: {
        body: {
          bytes: logBodyBytes
        }
      }
      response: {
        body: {
          bytes: logBodyBytes
        }
      }
    }
    backend: {
      request: {
        body: {
          bytes: logBodyBytes
        }
      }
      response: {
        body: {
          bytes: logBodyBytes
        }
      }
    }
  }
}
