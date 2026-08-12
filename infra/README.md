# Infraestructura como Código (Bicep)

Plantilla **portable** que despliega el entorno completo de la PoC (modelo LLM externo +
Azure Content Safety + Prompt Shield sobre API Management) de forma reproducible en
cualquier suscripción, sin credenciales en el código.

> ℹ️ **Backend del modelo:** GitHub Models fue retirado (30-jul-2026), así que la PoC
> redirige a un proveedor externo compatible con OpenAI. Por defecto **Groq**
> (`https://api.groq.com/openai/v1`, plan gratuito). Al usar el mismo esquema
> `Authorization: Bearer` y el mismo formato `/chat/completions`, las capas de seguridad
> (Content Safety / Prompt Shield) no cambian. Cambiar de proveedor = editar `base-url`
> en las políticas y el valor del secreto en Key Vault.

## ¿Qué despliega?

| Recurso | Módulo | Notas |
|---------|--------|-------|
| Log Analytics + Application Insights | `modules/loganalytics.bicep` | Destino de `ApiManagementGatewayLogs` (LA) y telemetría de request (App Insights) |
| Azure AI Content Safety | `modules/contentsafety.bicep` | Toxicidad + Prompt Shield (mismo recurso). `customSubDomainName` para auth AAD |
| Key Vault + secreto `model-api-token` | `modules/keyvault.bicep` | RBAC habilitado; único secreto de la solución |
| API Management (identidad gestionada) | `modules/apim.bicep` | SKU parametrizable (default `Developer`) |
| API `github-redirection` + 4 operaciones + políticas + Named Values | `modules/apim-apis.bicep` | Políticas cargadas desde `infra/policies/` |
| RBAC | `modules/rbac.bicep` | APIM → `Cognitive Services User` (CS) y `Key Vault Secrets User` (KV) |
| Diagnostic Settings APIM → LA | `modules/diagnostics.bicep` | `GatewayLogs` + métricas → Log Analytics. `logAnalyticsDestinationType: Dedicated` → tabla `ApiManagementGatewayLogs` (no la legacy `AzureDiagnostics`) |
| Loggers + Diagnostics APIM (App Insights + Azure Monitor) | `modules/apim-appinsights.bicep` | Diagnostic `applicationinsights` (telemetría request/dependencias) + diagnostic `azuremonitor` (captura `ResponseBody` en GatewayLogs, necesario para el desglose CS/PS de las KQL) |
| Workbook de seguridad | `modules/monitoring.bicep` | Desde `analytics/workbook-ai-security.json` |

## Modelo de seguridad (sin claves)

- **Content Safety / Prompt Shield:** APIM se autentica con su **Managed Identity**
  (rol `Cognitive Services User`). Las políticas usan `authentication-managed-identity`.
- **Token del proveedor de modelo:** almacenado en **Key Vault** y referenciado como Named Value
  `model-api-token` mediante Key Vault reference (rol `Key Vault Secrets User`).
- Los endpoints `content-safety-endpoint` y `promptshield-endpoint` (no secretos) se
  **derivan automáticamente** del recurso Content Safety creado.

> El orden de despliegue garantiza que la MI de APIM tenga acceso al Key Vault
> **antes** de crear el Named Value con la referencia (`apis` depende de `rbac`).

## Requisitos previos

> 🌍 **Región y grupo de recursos son libres.** La plantilla no fija ninguno: el RG se
> pasa con `--resource-group` y la región se hereda de él (`location = resourceGroup().location`);
> para forzar otra, añade `location=<region>` a `--parameters`. Asegúrate solo de elegir una
> región con **Content Safety** y tu **SKU de APIM** disponibles.

- Azure CLI (`az`) con sesión iniciada: `az login`
- Bicep CLI (incluido con `az`): `az bicep version`
- Un Resource Group destino: `az group create -n <rg> -l <region>`
- Un Personal Access Token de GitHub con acceso a GitHub Models

## Despliegue

```powershell
# 1. Login y selección de suscripción
az login
az account set --subscription "<subscription-id>"

# 2. Crear el Resource Group (elige nombre y región libremente)
az group create -n rg-apim-ai-security -l spaincentral

# 3. Desplegar (el token se inyecta en tiempo de despliegue, nunca se commitea)
az deployment group create `
  --resource-group rg-apim-ai-security `
  --template-file infra/main.bicep `
  --parameters apimPublisherEmail=admin@example.com `
               apimPublisherName="Mi Organizacion" `
               namePrefix=aisec `
               modelApiToken=$env:GROQ_API_KEY
```

O usando el fichero de parámetros (lee `GROQ_API_KEY` del entorno):

```powershell
$env:GROQ_API_KEY = "gsk_xxxxxxxx"
az deployment group create `
  --resource-group rg-apim-ai-security `
  --template-file infra/main.bicep `
  --parameters infra/main.bicepparam
```

### Validación previa (sin aplicar cambios)

```powershell
az deployment group what-if `
  --resource-group rg-apim-ai-security `
  --template-file infra/main.bicep `
  --parameters infra/main.bicepparam
```

## Parámetros principales

| Parámetro | Default | Descripción |
|-----------|---------|-------------|
| `namePrefix` | `aisec` | Prefijo de nombres (3-12 chars) |
| `nameSuffix` | `uniqueString(rg)` | Sufijo único para nombres globales |
| `apimPublisherEmail` | — | **Requerido** |
| `apimPublisherName` | — | **Requerido** |
| `apimSkuName` | `Developer` | `Developer`/`Basic`/`Standard`/`Premium`/`BasicV2`/`StandardV2` |
| `contentSafetySku` | `S0` | `F0` limitado a 1 por suscripción |
| `modelApiToken` | — | **Requerido** (`@secure()`) — API key del proveedor (Groq) |
| `logRetentionInDays` | `30` | 30-730 |

## Tras el despliegue

El despliegue devuelve los endpoints en `outputs.endpoints`. Cópialos a tu
`environment.env` local para usar `scripts/modelconn.py` / `tools/generate_events.py`
(o deja que [`../bootstrap.ps1`](../bootstrap.ps1) lo haga automáticamente):

```powershell
az deployment group show -g rg-apim-ai-security -n main --query properties.outputs.endpoints.value
```

## Pruebas

Guía completa end-to-end para validar en un tenant/suscripción vacío: [`TESTING.md`](TESTING.md)
(7 fases: prerrequisitos, validación, despliegue, verificación de config, pruebas
funcionales, analítica y limpieza).

Smoke test automático de la matriz funcional (Fase 4) con resumen PASS/FAIL:

```powershell
./infra/smoke-test.ps1 -ResourceGroup rg-apim-ai-security
```

Resuelve APIM, gateway y subscription key automáticamente y valida que cada capa
(Content Safety / Prompt Shield) bloquea lo esperado. Devuelve exit code 0 si todo pasa.

## Notas

- Las **políticas** en `infra/policies/` son la **fuente única** cargada por Bicep
  (`loadTextContent`, formato `rawxml`), donde el header `Authorization` usa el Named Value
  `{{model-api-token}}` (se elimina cualquier token hardcodeado).
- El SKU `Developer` de APIM **no** tiene SLA y su provisión tarda ~30-45 min.
- Para producción, considera SKU `StandardV2`/`Premium` y red privada.
