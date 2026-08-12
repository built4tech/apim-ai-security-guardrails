# Queries KQL para Monitorización de la Aplicación de IA

Colección de queries KQL para Azure Log Analytics orientadas a la operación
y monitorización de la aplicación de IA que utiliza GitHub Models a través de
Azure API Management con capas de seguridad (Content Safety + Prompt Shield).

**Tabla principal:** `ApiManagementGatewayLogs`  
**API:** `github-redirection`  
**Operación:** `github-cs-ps-redirection`  
**Filtro:** `Method == "POST"` (excluye peticiones GET de scanners/bots)  

---

## 1. VISIÓN GENERAL DE ACTIVIDAD

### 1.1 Dashboard general — Resumen de actividad (últimas 24h)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ApiId == "github-redirection"
| where Method == "POST"
| summarize
    TotalRequests = count(),
    SuccessfulRequests = countif(ResponseCode == 200),
    BlockedByContentSafety = countif(ResponseCode == 400 and ResponseBody has "Content Safety"),
    BlockedByPromptShield = countif(ResponseCode == 400 and ResponseBody has "Prompt Shield"),
    BackendErrors = countif(ResponseCode == 502),
    OtherErrors = countif(ResponseCode != 200 and ResponseCode != 400 and ResponseCode != 502),
    AvgLatencyMs = round(avg(TotalTime), 0),
    P95LatencyMs = round(percentile(TotalTime, 95), 0),
    UniqueUsers = dcount(CallerIpAddress)
```

### 1.2 Evolución temporal de peticiones (gráfico por horas)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ApiId == "github-redirection"
| where Method == "POST"
| summarize
    Total = count(),
    Exitosas = countif(ResponseCode == 200),
    Bloqueadas = countif(ResponseCode == 400),
    Errores = countif(ResponseCode >= 500)
    by bin(TimeGenerated, 1h)
| order by TimeGenerated asc
| render timechart
```

### 1.3 Tasa de éxito vs bloqueo a lo largo del tiempo

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| summarize
    Total = count(),
    Exitosas = countif(ResponseCode == 200),
    Bloqueadas = countif(ResponseCode == 400)
    by bin(TimeGenerated, 1d)
| extend
    TasaExito = round(100.0 * Exitosas / Total, 1),
    TasaBloqueo = round(100.0 * Bloqueadas / Total, 1)
| project TimeGenerated, Total, TasaExito, TasaBloqueo
| order by TimeGenerated asc
| render timechart
```

---

## 2. SEGURIDAD — CONTENT SAFETY

### 2.1 Peticiones bloqueadas por Content Safety (detalle)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ApiId == "github-redirection"
| where ResponseCode == 400
| where Method == "POST"
| where ResponseBody has "Content Safety"
| extend
    Prompt = extract(@"""content"":\s*""([^""]+)""", 1, RequestBody),
    BlockedBy = "Content Safety",
    FlaggedCategories = parse_json(ResponseBody).flagged_categories
| mv-expand FlaggedCategories
| extend
    Category = tostring(FlaggedCategories.category),
    Severity = toint(FlaggedCategories.severity)
| project TimeGenerated, CallerIpAddress, Prompt, BlockedBy, Category, Severity, TotalTime
| order by TimeGenerated desc
```

### 2.2 Categorías de Content Safety más frecuentes

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| where ResponseCode == 400
| where ResponseBody has "Content Safety"
| extend HasHate = ResponseBody has_cs "Hate"
| extend HasSelfHarm = ResponseBody has_cs "SelfHarm"
| extend HasSexual = ResponseBody has_cs "Sexual"
| extend HasViolence = ResponseBody has_cs "Violence"
| summarize
    Hate = countif(HasHate),
    SelfHarm = countif(HasSelfHarm),
    Sexual = countif(HasSexual),
    Violence = countif(HasViolence),
    Total = count()
| render barchart
```

### 2.3 Tendencia de violaciones de Content Safety por día

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(30d)
| where ApiId == "github-redirection"
| where Method == "POST"
| where ResponseCode == 400
| where ResponseBody has "Content Safety"
| summarize Violaciones = count() by bin(TimeGenerated, 1d)
| order by TimeGenerated asc
| render timechart with (title="Violaciones de Content Safety por día")
```

---

## 3. SEGURIDAD — PROMPT SHIELD (Jailbreak / Injection)

### 3.1 Intentos de jailbreak detectados (detalle)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ApiId == "github-redirection"
| where ResponseCode == 400
| where Method == "POST"
| where ResponseBody has "Prompt Shield"
| extend
    Prompt = extract(@"""content"":\s*""([^""]+)""", 1, RequestBody),
    BlockedBy = "Prompt Shield",
    Category = "Jailbreak/Injection",
    Severity = 10
| project TimeGenerated, CallerIpAddress, Prompt, BlockedBy, Category, Severity, TotalTime
| order by TimeGenerated desc
```

### 3.2 Top IPs con más intentos de jailbreak (últimos 7 días)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| where ResponseCode == 400
| where ResponseBody has "Prompt Shield"
| summarize
    IntentosJailbreak = count(),
    PrimerIntento = min(TimeGenerated),
    UltimoIntento = max(TimeGenerated)
    by CallerIpAddress
| order by IntentosJailbreak desc
| take 20
```

### 3.3 Tendencia de intentos de jailbreak por día

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(30d)
| where ApiId == "github-redirection"
| where Method == "POST"
| where ResponseCode == 400
| where ResponseBody has "Prompt Shield"
| summarize Intentos = count() by bin(TimeGenerated, 1d)
| order by TimeGenerated asc
| render timechart with (title="Intentos de Jailbreak por día")
```

---

## 4. SEGURIDAD — VISTA COMBINADA

### 4.1 Detalle de bloqueos con categoría y severidad (Content Safety + Prompt Shield)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ApiId == "github-redirection"
| where ResponseCode == 400
| where Method == "POST"
| where ResponseBody has "Content Safety" or ResponseBody has "Prompt Shield"
| extend
    Prompt = extract(@"""content"":\s*""([^""]+)""", 1, RequestBody),
    BlockedBy = case(
        ResponseBody has "Prompt Shield", "Prompt Shield",
        ResponseBody has "Content Safety", "Content Safety",
        "Unknown"
    ),
    FlaggedCategories = parse_json(ResponseBody).flagged_categories
| mv-expand FlaggedCategories
| extend
    Category = case(
        BlockedBy == "Prompt Shield", "Jailbreak/Injection",
        isnotempty(tostring(FlaggedCategories.category)), tostring(FlaggedCategories.category),
        "Unknown"
    ),
    Severity = case(
        BlockedBy == "Prompt Shield", 10,
        toint(FlaggedCategories.severity)
    )
| project TimeGenerated, CallerIpAddress, Prompt, BlockedBy, Category, Severity, TotalTime
| order by TimeGenerated desc
```

### 4.2 Distribución de bloqueos por tipo de seguridad

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| where ResponseCode == 400
| extend BlockedBy = case(
    ResponseBody has "Prompt Shield", "Prompt Shield",
    ResponseBody has "Content Safety", "Content Safety",
    "Otro"
)
| summarize Bloqueos = count() by BlockedBy
| render piechart with (title="Distribución de bloqueos por capa de seguridad")
```

### 4.3 Usuarios con más bloqueos (indicador de abuso)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| where ResponseCode == 400
| extend BlockedBy = case(
    ResponseBody has "Prompt Shield", "Prompt Shield",
    ResponseBody has "Content Safety", "Content Safety",
    "Otro"
)
| summarize
    TotalBloqueos = count(),
    BloqueosPorJailbreak = countif(BlockedBy == "Prompt Shield"),
    BloqueosPorToxicidad = countif(BlockedBy == "Content Safety")
    by CallerIpAddress
| order by TotalBloqueos desc
| take 20
```

---

## 5. RENDIMIENTO Y LATENCIA

### 5.1 Latencia media y percentiles por hora

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ApiId == "github-redirection"
| where Method == "POST"
| where ResponseCode == 200
| summarize
    AvgMs = round(avg(TotalTime), 0),
    P50Ms = round(percentile(TotalTime, 50), 0),
    P90Ms = round(percentile(TotalTime, 90), 0),
    P95Ms = round(percentile(TotalTime, 95), 0),
    P99Ms = round(percentile(TotalTime, 99), 0),
    MaxMs = max(TotalTime)
    by bin(TimeGenerated, 1h)
| order by TimeGenerated asc
| render timechart
```

### 5.2 Sobrecarga de las capas de seguridad (TotalTime vs BackendTime)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ApiId == "github-redirection"
| where Method == "POST"
| where ResponseCode == 200
| where isnotempty(BackendTime)
| extend
    SecurityOverheadMs = TotalTime - BackendTime,
    SecurityOverheadPct = round(100.0 * (TotalTime - BackendTime) / TotalTime, 1)
| summarize
    AvgTotalMs = round(avg(TotalTime), 0),
    AvgBackendMs = round(avg(BackendTime), 0),
    AvgSecurityOverheadMs = round(avg(SecurityOverheadMs), 0),
    AvgSecurityOverheadPct = round(avg(SecurityOverheadPct), 1)
    by bin(TimeGenerated, 1h)
| order by TimeGenerated asc
```

### 5.3 Peticiones lentas (> 5 segundos)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ApiId == "github-redirection"
| where Method == "POST"
| where TotalTime > 5000
| extend
    Prompt = extract(@"""content"":\s*""([^""]+)""", 1, RequestBody),
    Model = extract(@"""model"":\s*""([^""]+)""", 1, RequestBody)
| project TimeGenerated, CallerIpAddress, ResponseCode, TotalTime, BackendTime, Model, Prompt
| order by TotalTime desc
```

---

## 6. ANÁLISIS DE USO

### 6.1 Actividad por usuario (IP) — Top 20

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| summarize
    TotalPeticiones = count(),
    Exitosas = countif(ResponseCode == 200),
    Bloqueadas = countif(ResponseCode == 400),
    PrimeraActividad = min(TimeGenerated),
    UltimaActividad = max(TimeGenerated)
    by CallerIpAddress
| extend TasaBloqueo = round(100.0 * Bloqueadas / TotalPeticiones, 1)
| order by TotalPeticiones desc
| take 20
```

### 6.2 Modelos de IA más utilizados

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| where isnotempty(RequestBody)
| extend Model = extract(@"""model"":\s*""([^""]+)""", 1, RequestBody)
| where isnotempty(Model)
| summarize
    Peticiones = count(),
    Exitosas = countif(ResponseCode == 200),
    AvgLatencyMs = round(avg(TotalTime), 0)
    by Model
| order by Peticiones desc
```

### 6.3 Distribución horaria de uso (patrón de actividad)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| extend HoraUTC = hourofday(TimeGenerated)
| summarize Peticiones = count() by HoraUTC
| order by HoraUTC asc
| render columnchart with (title="Distribución de uso por hora (UTC)")
```

### 6.4 Actividad por suscripción de APIM

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| summarize
    Peticiones = count(),
    Exitosas = countif(ResponseCode == 200),
    Bloqueadas = countif(ResponseCode == 400),
    AvgLatencyMs = round(avg(TotalTime), 0)
    by ApimSubscriptionId
| order by Peticiones desc
```

---

## 7. ANÁLISIS DE TOKENS Y COSTES

### 7.1 Consumo de tokens por petición exitosa

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ApiId == "github-redirection"
| where Method == "POST"
| where ResponseCode == 200
| where isnotempty(BackendResponseBody)
| extend
    PromptTokens = toint(extract(@"""prompt_tokens"":(\d+)", 1, BackendResponseBody)),
    CompletionTokens = toint(extract(@"""completion_tokens"":(\d+)", 1, BackendResponseBody)),
    TotalTokens = toint(extract(@"""total_tokens"":(\d+)", 1, BackendResponseBody)),
    Model = extract(@"""model"":\s*""([^""]+)""", 1, RequestBody)
| where isnotnull(TotalTokens)
| project TimeGenerated, CallerIpAddress, Model, PromptTokens, CompletionTokens, TotalTokens, TotalTime
| order by TotalTokens desc
```

### 7.2 Consumo total de tokens por día y modelo

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(30d)
| where ApiId == "github-redirection"
| where Method == "POST"
| where ResponseCode == 200
| where isnotempty(BackendResponseBody)
| extend
    TotalTokens = toint(extract(@"""total_tokens"":(\d+)", 1, BackendResponseBody)),
    Model = extract(@"""model"":\s*""([^""]+)""", 1, BackendResponseBody)
| where isnotnull(TotalTokens)
| summarize
    Peticiones = count(),
    TokensConsumidos = sum(TotalTokens),
    AvgTokensPorPeticion = round(avg(TotalTokens), 0)
    by bin(TimeGenerated, 1d), Model
| order by TimeGenerated asc
| render timechart
```

### 7.3 Top usuarios por consumo de tokens

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| where ResponseCode == 200
| where isnotempty(BackendResponseBody)
| extend TotalTokens = toint(extract(@"""total_tokens"":(\d+)", 1, BackendResponseBody))
| where isnotnull(TotalTokens)
| summarize
    Peticiones = count(),
    TokensTotales = sum(TotalTokens),
    AvgTokens = round(avg(TotalTokens), 0),
    MaxTokens = max(TotalTokens)
    by CallerIpAddress
| order by TokensTotales desc
| take 20
```

---

## 8. DETECCIÓN DE ANOMALÍAS Y ACTIVIDAD SOSPECHOSA

### 8.1 IPs con ratio sospechoso de bloqueos (> 50%)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| summarize
    Total = count(),
    Bloqueadas = countif(ResponseCode == 400)
    by CallerIpAddress
| where Total >= 3
| extend RatioBloqueo = round(100.0 * Bloqueadas / Total, 1)
| where RatioBloqueo > 50.0
| order by RatioBloqueo desc, Total desc
```

### 8.2 Ráfagas de peticiones (posible abuso automatizado)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ApiId == "github-redirection"
| where Method == "POST"
| summarize PeticionesPorMinuto = count() by CallerIpAddress, bin(TimeGenerated, 1m)
| where PeticionesPorMinuto > 5
| project TimeGenerated, CallerIpAddress, PeticionesPorMinuto
| order by PeticionesPorMinuto desc
```

### 8.3 Intentos desde IPs no habituales (primera vez en últimos 7 días)

```kql
let IPsConocidas = ApiManagementGatewayLogs
| where TimeGenerated between (ago(30d) .. ago(7d))
| where ApiId == "github-redirection"
| where Method == "POST"
| distinct CallerIpAddress;
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| where CallerIpAddress !in (IPsConocidas)
| summarize
    Peticiones = count(),
    Bloqueadas = countif(ResponseCode == 400),
    PrimeraVez = min(TimeGenerated)
    by CallerIpAddress
| order by Peticiones desc
```

### 8.4 Escaneos y peticiones a rutas inexistentes (bots/scanners)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ResponseCode == 404
| where LastErrorReason == "OperationNotFound"
| summarize
    Intentos = count(),
    Rutas = make_set(Url, 50)
    by CallerIpAddress
| order by Intentos desc
```

---

## 9. ANÁLISIS DE PROMPTS

### 9.1 Últimas peticiones exitosas con prompt y respuesta

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ApiId == "github-redirection"
| where Method == "POST"
| where ResponseCode == 200
| where isnotempty(RequestBody)
| extend
    Prompt = extract(@"""content"":\s*""([^""]+)""", 1, RequestBody),
    Model = extract(@"""model"":\s*""([^""]+)""", 1, RequestBody),
    Respuesta = extract(@"""content"":\s*""(.*?)(?="",""refusal)", 1, BackendResponseBody)
| project TimeGenerated, CallerIpAddress, Model, Prompt, Respuesta, TotalTime
| order by TimeGenerated desc
| take 50
```

### 9.2 Longitud media de prompts y respuestas

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| where ResponseCode == 200
| where isnotempty(RequestBody)
| extend
    PromptLen = strlen(extract(@"""content"":\s*""([^""]+)""", 1, RequestBody)),
    RequestBytes = RequestSize,
    ResponseBytes = ResponseSize
| summarize
    AvgPromptChars = round(avg(PromptLen), 0),
    AvgRequestBytes = round(avg(RequestBytes), 0),
    AvgResponseBytes = round(avg(ResponseBytes), 0),
    MaxRequestBytes = max(RequestBytes),
    MaxResponseBytes = max(ResponseBytes)
    by bin(TimeGenerated, 1d)
| order by TimeGenerated asc
```

---

## 10. ERRORES Y DIAGNÓSTICO

### 10.1 Errores de backend (502 — Content Safety / Prompt Shield caído)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ApiId == "github-redirection"
| where Method == "POST"
| where ResponseCode == 502
| project TimeGenerated, CallerIpAddress, ResponseBody, LastErrorReason, LastErrorMessage, TotalTime
| order by TimeGenerated desc
```

### 10.2 Distribución de códigos de respuesta

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| summarize Peticiones = count() by tostring(ResponseCode)
| order by Peticiones desc
| render piechart with (title="Distribución de códigos HTTP")
```

### 10.3 Errores agrupados por tipo y razón

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| where ResponseCode >= 400
| extend ErrorType = case(
    ResponseCode == 400 and ResponseBody has "Prompt Shield", "Prompt Shield Block",
    ResponseCode == 400 and ResponseBody has "Content Safety", "Content Safety Block",
    ResponseCode == 502, "Backend Error (502)",
    ResponseCode == 404, "Not Found (404)",
    strcat("HTTP ", tostring(ResponseCode))
)
| summarize Ocurrencias = count() by ErrorType
| order by Ocurrencias desc
| render barchart
```

### 10.4 Peticiones sin body en los logs (posible problema de configuración)

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| where ApiId == "github-redirection"
| where Method == "POST"
| where ResponseCode == 200
| where isempty(RequestBody) or isempty(BackendResponseBody)
| summarize
    SinRequestBody = countif(isempty(RequestBody)),
    SinResponseBody = countif(isempty(ResponseBody)),
    SinBackendRequestBody = countif(isempty(BackendRequestBody)),
    SinBackendResponseBody = countif(isempty(BackendResponseBody)),
    Total = count()
```

---

## 11. INFORME EJECUTIVO

### 11.1 Resumen semanal para reporte

```kql
ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| summarize
    TotalPeticiones = count(),
    PeticionesExitosas = countif(ResponseCode == 200),
    BloqueosContentSafety = countif(ResponseCode == 400 and ResponseBody has "Content Safety"),
    BloqueosPromptShield = countif(ResponseCode == 400 and ResponseBody has "Prompt Shield"),
    ErroresBackend = countif(ResponseCode >= 500),
    UsuariosUnicos = dcount(CallerIpAddress),
    LatenciaMediaMs = round(avg(TotalTime), 0),
    LatenciaP95Ms = round(percentile(TotalTime, 95), 0)
| extend
    TasaExito = round(100.0 * PeticionesExitosas / TotalPeticiones, 1),
    TasaBloqueo = round(100.0 * (BloqueosContentSafety + BloqueosPromptShield) / TotalPeticiones, 1),
    TotalBloqueos = BloqueosContentSafety + BloqueosPromptShield
```

### 11.2 Comparativa semana actual vs semana anterior

```kql
let SemanaActual = ApiManagementGatewayLogs
| where TimeGenerated > ago(7d)
| where ApiId == "github-redirection"
| where Method == "POST"
| summarize
    Peticiones = count(),
    Exitosas = countif(ResponseCode == 200),
    Bloqueadas = countif(ResponseCode == 400),
    AvgLatency = round(avg(TotalTime), 0)
| extend Periodo = "Semana actual";
let SemanaAnterior = ApiManagementGatewayLogs
| where TimeGenerated between (ago(14d) .. ago(7d))
| where ApiId == "github-redirection"
| where Method == "POST"
| summarize
    Peticiones = count(),
    Exitosas = countif(ResponseCode == 200),
    Bloqueadas = countif(ResponseCode == 400),
    AvgLatency = round(avg(TotalTime), 0)
| extend Periodo = "Semana anterior";
union SemanaActual, SemanaAnterior
| project Periodo, Peticiones, Exitosas, Bloqueadas, AvgLatency
```
