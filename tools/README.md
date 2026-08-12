# Scripts de apoyo (`tools/`)

Utilidades auxiliares para la PoC. **No** son necesarias para la demostración básica
(`python scripts/modelconn.py`); sirven para configurar protecciones custom y para
generar datos de analítica.

Todos leen la configuración desde `environment.env` en la **raíz del repo**
(resuelto con `Path(__file__).resolve().parent.parent`).

---

## `ContentSafetySetup.py` — Protecciones custom (blocklists)

Crea y prueba **listas de bloqueo personalizadas** (blocklists) en Azure AI Content Safety,
además de ejercitar Prompt Shield y las categorías estándar (Hate, SelfHarm, Sexual, Violence).

**Qué hace:**
1. Crea/actualiza la blocklist `ApimAiSecurityCustomPolicy`.
2. Añade palabras prohibidas de ejemplo (`competencia`, `secreto`, `confidencial`, `clave_maestra`).
3. Modo interactivo para analizar **entrada** (prompt: Prompt Shield + categorías + blocklist)
   o **salida** (completion: categorías + blocklist).

**Variables de `environment.env` que usa:**
- `CONTENT_SAFETY_ENDPOINT`
- `CONTENT_SAFETY_KEY`

> ⚠️ **Limitación de autenticación.** Este script se autentica con **API key**
> (`Ocp-Apim-Subscription-Key`). La plantilla Bicep crea el recurso de Content Safety con
> `disableLocalAuth: true` (solo Managed Identity), por lo que **con la infraestructura
> desplegada por `bootstrap.ps1` este script devolverá `401`**. Para usarlo tienes dos opciones:
> 1. Habilitar temporalmente la autenticación local en el recurso de Content Safety
>    (`az cognitiveservices account update ... --custom-domain ... ` / propiedad `disableLocalAuth=false`)
>    y rellenar `CONTENT_SAFETY_KEY` con una de las claves del recurso.
> 2. Adaptar el script para usar un token AAD (`Authorization: Bearer <token>`) en lugar de la API key.
>
> Queda **fuera del alcance del bootstrap** por diseño (la PoC prioriza el patrón sin claves).

**Ejecución:**
```bash
python tools/ContentSafetySetup.py
```

---

## `generate_events.py` — Tráfico sintético para analítica

Genera eventos de prueba contra el endpoint de APIM con Content Safety + Prompt Shield,
para poblar Log Analytics / Application Insights y alimentar el Workbook (`analytics/`).
Envía una mezcla de prompts que disparan Content Safety, prompts de jailbreak (Prompt Shield)
y peticiones normales.

**Variables de `environment.env` que usa:**
- `AZURE_APIM_ENDPOINT_CS_PS`
- `AZURE_APIM_KEY`

**Modelos** (identificadores de Groq, con fallback ante throttling):
`llama-3.3-70b-versatile`, `llama-3.1-8b-instant`.

**Ejecución:**
```bash
python tools/generate_events.py
```

Después, revisa las consultas KQL en [`../analytics/kql_queries.md`](../analytics/kql_queries.md)
y el Workbook `../analytics/workbook-ai-security.json`.

---

## `purview/` — Scripts auxiliares de Microsoft Purview

Scripts de PowerShell relacionados con etiquetas de sensibilidad de Microsoft Purview
(tangenciales a la PoC de seguridad de IA). Ver el `README.md` dentro de la carpeta.
