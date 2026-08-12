<#
.SYNOPSIS
    Automatiza el ciclo de vida completo del entorno Azure de la PoC
    (API Management + Content Safety + Prompt Shield sobre un modelo externo/Groq).

.DESCRIPTION
    Acción 'create':
      1. Comprueba prerrequisitos (az, python) y la sesión de Azure.
      2. Pregunta interactivamente RG, región, prefijo y la API key de Groq (con valores por defecto).
      3. Registra los Resource Providers necesarios.
      4. Crea el Resource Group y despliega infra/main.bicep.
      5. Recoge las salidas del despliegue y la subscription key 'master' de APIM.
      6. Reescribe environment.env con los valores reales (preservando GROQ_API_KEY).
      7. Ejecuta el smoke test (infra/smoke-test.ps1) salvo -SkipSmokeTest.
      8. Deja el entorno listo para 'python scripts/modelconn.py'.

    Acción 'remove':
      1. Elimina el Resource Group.
      2. Purga el soft-delete de Key Vault y Content Safety (recrear con el mismo nombre).
      3. Conserva la API key de Groq en environment.env (vacía el resto de variables Azure).

.PARAMETER Action
    'create' (por defecto) o 'remove'.

.PARAMETER ResourceGroup
    Nombre del Resource Group. Default: rg-apim-ai-security.

.PARAMETER Location
    Región de Azure. Default: spaincentral.

.PARAMETER NamePrefix
    Prefijo corto (3-12 chars) para nombrar los recursos. Default: aisec.

.PARAMETER GroqApiKey
    API key de Groq. Si se omite, se reutiliza la de environment.env o se pregunta.

.PARAMETER PublisherEmail
    Email del publicador de APIM. Default: admin@example.com.

.PARAMETER PublisherName
    Nombre del publicador de APIM. Default: "AI Security PoC".

.PARAMETER Model
    Modelo del proveedor para el smoke test. Default: llama-3.3-70b-versatile.

.PARAMETER SkipSmokeTest
    No ejecutar el smoke test tras el despliegue.

.PARAMETER Yes
    No pedir confirmaciones interactivas (útil para automatización / CI).

.EXAMPLE
    ./bootstrap.ps1 create

.EXAMPLE
    ./bootstrap.ps1 remove -Yes
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('create', 'remove')]
    [string]$Action = 'create',

    [string]$ResourceGroup,
    [string]$Location,
    [string]$NamePrefix,
    [string]$GroqApiKey,
    [string]$PublisherEmail,
    [string]$PublisherName,
    [string]$Model = 'llama-3.3-70b-versatile',
    [switch]$SkipSmokeTest,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

# ─── Rutas ────────────────────────────────────────────────────────────────────
$RepoRoot    = $PSScriptRoot
$InfraDir    = Join-Path $RepoRoot 'infra'
$BicepFile   = Join-Path $InfraDir 'main.bicep'
$BicepParam  = Join-Path $InfraDir 'main.bicepparam'
$SmokeTest   = Join-Path $InfraDir 'smoke-test.ps1'
$EnvFile     = Join-Path $RepoRoot 'environment.env'
$StateFile   = Join-Path $RepoRoot '.bootstrap-state.json'
$DeployName  = 'main'

# Valores por defecto (los pedidos por el usuario)
$DefaultRg       = 'rg-apim-ai-security'
$DefaultLocation = 'spaincentral'
$DefaultPrefix   = 'aisec'
$DefaultEmail    = 'admin@example.com'
$DefaultName     = 'AI Security PoC'

# ─── Helpers de salida ────────────────────────────────────────────────────────
function Write-Step($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-Info($t) { Write-Host "  $t" -ForegroundColor Gray }
function Write-Ok($t)   { Write-Host "  [OK] $t" -ForegroundColor Green }
function Write-Warn2($t){ Write-Host "  [!] $t" -ForegroundColor Yellow }
function Write-ErrX($t) { Write-Host "  [X] $t" -ForegroundColor Red }

function Read-WithDefault($prompt, $default) {
    $val = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($val)) { return $default }
    return $val.Trim()
}

function Mask($s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return '(vacío)' }
    if ($s.Length -le 8) { return ('*' * $s.Length) }
    return $s.Substring(0, 6) + '...' + $s.Substring($s.Length - 2)
}

function Invoke-AzOrThrow {
    param([Parameter(Mandatory)][string[]]$Args, [string]$What = 'comando az')
    $out = & az @Args
    if ($LASTEXITCODE -ne 0) {
        throw "Falló $What (az $($Args -join ' '))"
    }
    return $out
}

# ─── Prerrequisitos ───────────────────────────────────────────────────────────
function Test-Prerequisites {
    Write-Step 'Comprobando prerrequisitos'

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI (az) no está instalado o no está en el PATH."
    }
    Write-Ok "Azure CLI disponible"

    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Warn2 "Python no encontrado; los scripts de demostración lo necesitarán."
    } else {
        Write-Ok "Python disponible"
    }

    # Sesión de Azure
    $acct = az account show -o json 2>$null | ConvertFrom-Json
    if (-not $acct) {
        Write-Info "No hay sesión de Azure activa. Iniciando 'az login'..."
        az login | Out-Null
        $acct = az account show -o json 2>$null | ConvertFrom-Json
        if (-not $acct) { throw "No se pudo iniciar sesión en Azure." }
    }
    Write-Ok "Suscripción activa: $($acct.name)"
    Write-Info "Tenant: $($acct.tenantId)"

    if (-not $Yes) {
        $c = Read-Host "¿Continuar con esta suscripción? (s/N)"
        if ($c -notmatch '^[sSyY]') { throw "Cancelado por el usuario. Usa 'az account set --subscription <id>' para cambiar." }
    }
}

# ─── environment.env ──────────────────────────────────────────────────────────
function Get-GroqKeyFromEnvFile {
    if (-not (Test-Path $EnvFile)) { return $null }
    $line = Select-String -Path $EnvFile -Pattern '^\s*GROQ_API_KEY\s*=\s*(.+)\s*$' | Select-Object -First 1
    if ($line) {
        $v = $line.Matches[0].Groups[1].Value.Trim()
        if ($v) { return $v }
    }
    return $null
}

function Write-EnvFile {
    param(
        [string]$GroqKey,
        [string]$ApimKey,
        [string]$EndpointDirect,
        [string]$EndpointCs,
        [string]$EndpointPs,
        [string]$EndpointCsPs,
        [string]$ContentSafetyEndpoint
    )

    $csTrim = if ($ContentSafetyEndpoint) { $ContentSafetyEndpoint.TrimEnd('/') } else { '' }
    $promptShield = if ($csTrim) { "$csTrim/contentsafety/text:shieldPrompt?api-version=2024-09-01" } else { '' }

    $content = @"
######################################
# TOKENS
######################################
# API key de Groq (https://console.groq.com -> API Keys).
# APIM la lee desde Key Vault (secreto model-api-token); el cliente directo (opción 1) la usa vía Bearer.
GROQ_API_KEY=$GroqKey

# Subscription key 'master' de Azure API Management (generada por bootstrap.ps1).
AZURE_APIM_KEY=$ApimKey

# Content Safety usa Managed Identity (disableLocalAuth=true en la plantilla Bicep).
# Por eso NO se rellena una key aquí. El script tools/ContentSafetySetup.py, que usa
# CONTENT_SAFETY_KEY, requeriría habilitar la autenticación local (ver tools/README.md).
CONTENT_SAFETY_KEY=

######################################
# ENDPOINTS
######################################
# Conexión directa al proveedor de modelo (Groq) — opción 1 de modelconn.py
GROQ_ENDPOINT=https://api.groq.com/openai/v1/chat/completions

# Conexión via Azure API Management (sin seguridad)
AZURE_APIM_ENDPOINT=$EndpointDirect
# Conexión via APIM + Content Safety
AZURE_APIM_ENDPOINT_CS=$EndpointCs
# Conexión via APIM + Prompt Shield
AZURE_APIM_ENDPOINT_PS=$EndpointPs
# Conexión via APIM + Content Safety & Prompt Shield
AZURE_APIM_ENDPOINT_CS_PS=$EndpointCsPs

# Content Safety
CONTENT_SAFETY_ENDPOINT=$ContentSafetyEndpoint
PROMPT_SHIELD_ENDPOINT=$promptShield
"@

    Set-Content -Path $EnvFile -Value $content -Encoding UTF8
}

function Write-EnvFileGroqOnly {
    param([string]$GroqKey)
    $content = @"
######################################
# TOKENS
######################################
# API key de Groq preservada tras 'remove'. Vuelve a ejecutar 'bootstrap.ps1 create'
# para regenerar el resto de variables (endpoints y subscription key de APIM).
GROQ_API_KEY=$GroqKey

AZURE_APIM_KEY=
CONTENT_SAFETY_KEY=

######################################
# ENDPOINTS
######################################
# Conexión directa al proveedor de modelo (Groq) — opción 1 de modelconn.py
GROQ_ENDPOINT=https://api.groq.com/openai/v1/chat/completions

AZURE_APIM_ENDPOINT=
AZURE_APIM_ENDPOINT_CS=
AZURE_APIM_ENDPOINT_PS=
AZURE_APIM_ENDPOINT_CS_PS=

CONTENT_SAFETY_ENDPOINT=
PROMPT_SHIELD_ENDPOINT=
"@
    Set-Content -Path $EnvFile -Value $content -Encoding UTF8
}

# ─── Estado (.bootstrap-state.json) ───────────────────────────────────────────
function Save-State($obj) {
    $obj | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}
function Load-State {
    if (Test-Path $StateFile) {
        return Get-Content -Path $StateFile -Raw | ConvertFrom-Json
    }
    return $null
}

# ─── Registro de Resource Providers ───────────────────────────────────────────
function Register-Providers {
    Write-Step 'Registrando Resource Providers'
    $rps = @(
        'Microsoft.ApiManagement',
        'Microsoft.CognitiveServices',
        'Microsoft.KeyVault',
        'Microsoft.OperationalInsights',
        'Microsoft.Insights',
        'Microsoft.Authorization'
    )
    foreach ($rp in $rps) {
        az provider register --namespace $rp 2>$null | Out-Null
        Write-Info "solicitado: $rp"
    }
    Write-Ok "Registro solicitado (puede tardar unos minutos en completarse en segundo plano)."
}

# ─── Purga de recursos en soft-delete (auto-sanación de 'create') ──────────────
function Clear-SoftDeleted {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$NamePrefix
    )
    Write-Step 'Comprobando recursos en soft-delete que puedan colisionar'
    $rgToken = "/resourceGroups/$ResourceGroup/"
    $found = $false

    # APIM: la lista de borrados no incluye RG, se filtra por prefijo + localización.
    $delApim = az apim deletedservice list -o json 2>$null | ConvertFrom-Json
    foreach ($a in @($delApim)) {
        if ($a.name -like "$NamePrefix-apim-*") {
            Write-Info "Purgando APIM en soft-delete '$($a.name)'..."
            az apim deletedservice purge --service-name $a.name --location $Location --output none 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Ok "APIM '$($a.name)' purgado."; $found = $true }
        }
    }

    # Content Safety: se identifica por el resource id (contiene el RG).
    $delCs = az cognitiveservices account list-deleted -o json 2>$null | ConvertFrom-Json
    foreach ($c in @($delCs)) {
        if ($c.id -and ($c.id -like "*$rgToken*")) {
            Write-Info "Purgando Content Safety en soft-delete '$($c.name)'..."
            az cognitiveservices account purge --name $c.name --resource-group $ResourceGroup --location $Location --output none 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Ok "Content Safety '$($c.name)' purgado."; $found = $true }
        }
    }

    # Key Vault: se identifica por vaultId (contiene el RG).
    $delKv = az keyvault list-deleted -o json 2>$null | ConvertFrom-Json
    foreach ($k in @($delKv)) {
        $vid = $k.properties.vaultId
        if ($vid -and ($vid -like "*$rgToken*")) {
            $kvLoc = if ($k.properties.location) { $k.properties.location } else { $Location }
            Write-Info "Purgando Key Vault en soft-delete '$($k.name)'..."
            az keyvault purge --name $k.name --location $kvLoc --output none 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Ok "Key Vault '$($k.name)' purgado."; $found = $true }
        }
    }

    if (-not $found) { Write-Info "No hay recursos en soft-delete que purgar." }
}

# ════════════════════════════════════════════════════════════════════════════
# CREATE
# ════════════════════════════════════════════════════════════════════════════
function Invoke-Create {
    Test-Prerequisites

    Write-Step 'Parámetros del despliegue'
    if (-not $ResourceGroup)  { $ResourceGroup  = if ($Yes) { $DefaultRg }       else { Read-WithDefault 'Resource Group' $DefaultRg } }
    if (-not $Location)       { $Location       = if ($Yes) { $DefaultLocation } else { Read-WithDefault 'Región (location)' $DefaultLocation } }
    if (-not $NamePrefix)     { $NamePrefix     = if ($Yes) { $DefaultPrefix }   else { Read-WithDefault 'Prefijo de nombres (3-12 chars)' $DefaultPrefix } }
    if (-not $PublisherEmail) { $PublisherEmail = if ($Yes) { $DefaultEmail }    else { Read-WithDefault 'Email publicador APIM' $DefaultEmail } }
    if (-not $PublisherName)  { $PublisherName  = if ($Yes) { $DefaultName }     else { Read-WithDefault 'Nombre publicador APIM' $DefaultName } }

    # API key de Groq
    if (-not $GroqApiKey) {
        $existing = Get-GroqKeyFromEnvFile
        if ($existing) {
            Write-Info "Encontrada GROQ_API_KEY en environment.env ($(Mask $existing))."
            if ($Yes) {
                $GroqApiKey = $existing
            } else {
                $r = Read-Host "¿Reutilizarla? (S/n)"
                if ($r -match '^[nN]') { $GroqApiKey = Read-Host 'Introduce la API key de Groq' } else { $GroqApiKey = $existing }
            }
        } else {
            $GroqApiKey = Read-Host 'Introduce la API key de Groq (https://console.groq.com)'
        }
    }
    if ([string]::IsNullOrWhiteSpace($GroqApiKey)) { throw "La API key de Groq es obligatoria." }

    Write-Host ""
    Write-Info "Resource Group : $ResourceGroup"
    Write-Info "Región         : $Location"
    Write-Info "Prefijo        : $NamePrefix"
    Write-Info "Publicador     : $PublisherName <$PublisherEmail>"
    Write-Info "Groq API key   : $(Mask $GroqApiKey)"
    if (-not $Yes) {
        $c = Read-Host "`n¿Proceder con el despliegue? (s/N)"
        if ($c -notmatch '^[sSyY]') { throw "Cancelado por el usuario." }
    }

    Register-Providers

    Write-Step "Creando Resource Group '$ResourceGroup'"
    Invoke-AzOrThrow -What 'crear el Resource Group' -Args @(
        'group', 'create', '--name', $ResourceGroup, '--location', $Location, '--output', 'none'
    )
    Write-Ok "Resource Group listo."

    # Auto-sanación: purga recursos en soft-delete que colisionarían con este despliegue
    # (p.ej. restos de un 'create' anterior fallido o un 'remove' incompleto). Sin esto,
    # el redespliegue falla con FlagMustBeSetForRestore (CS/KV) o
    # ServiceAlreadyExistsInSoftDeletedState (APIM).
    Clear-SoftDeleted -ResourceGroup $ResourceGroup -Location $Location -NamePrefix $NamePrefix

    Write-Step 'Desplegando la infraestructura (Bicep)'
    Write-Warn2 "APIM (SKU Developer) puede tardar ~30-45 minutos. Ten paciencia..."
    Invoke-AzOrThrow -What 'el despliegue Bicep' -Args @(
        'deployment', 'group', 'create',
        '--resource-group', $ResourceGroup,
        '--name', $DeployName,
        '--template-file', $BicepFile,
        '--parameters', $BicepParam,
        '--parameters',
        "namePrefix=$NamePrefix",
        "location=$Location",
        "apimPublisherEmail=$PublisherEmail",
        "apimPublisherName=$PublisherName",
        "modelApiToken=$GroqApiKey",
        '--output', 'none'
    )
    Write-Ok "Despliegue completado."

    Write-Step 'Recogiendo salidas del despliegue'
    $outputsJson = Invoke-AzOrThrow -What 'leer outputs' -Args @(
        'deployment', 'group', 'show', '-g', $ResourceGroup, '-n', $DeployName,
        '--query', 'properties.outputs', '-o', 'json'
    )
    $o = $outputsJson | ConvertFrom-Json

    $apimName   = $o.apimName.value
    $endpoints  = $o.endpoints.value
    $csEndpoint = $o.contentSafetyEndpoint.value
    $kvName     = $o.keyVaultName.value
    $csName     = $o.contentSafetyName.value

    Write-Info "APIM            : $apimName"
    Write-Info "Content Safety  : $csName"
    Write-Info "Key Vault       : $kvName"

    Write-Step 'Obteniendo subscription key (master) de APIM'
    $apimId = Invoke-AzOrThrow -What 'obtener el id de APIM' -Args @(
        'apim', 'show', '-g', $ResourceGroup, '-n', $apimName, '--query', 'id', '-o', 'tsv'
    )
    $subKey = Invoke-AzOrThrow -What 'obtener la subscription key' -Args @(
        'rest', '--method', 'post',
        '--url', "https://management.azure.com$apimId/subscriptions/master/listSecrets?api-version=2022-08-01",
        '--query', 'primaryKey', '-o', 'tsv'
    )
    if (-not $subKey) { throw "No se pudo obtener la subscription key 'master'." }
    Write-Ok "Subscription key obtenida ($(Mask $subKey))."

    Write-Step 'Escribiendo environment.env'
    Write-EnvFile -GroqKey $GroqApiKey -ApimKey $subKey `
        -EndpointDirect $endpoints.direct -EndpointCs $endpoints.contentSafety `
        -EndpointPs $endpoints.promptShield -EndpointCsPs $endpoints.contentSafetyAndPromptShield `
        -ContentSafetyEndpoint $csEndpoint
    Write-Ok "environment.env actualizado."

    # Guardar estado para 'remove'
    Save-State ([pscustomobject]@{
        resourceGroup     = $ResourceGroup
        location          = $Location
        namePrefix        = $NamePrefix
        deploymentName    = $DeployName
        apimName          = $apimName
        keyVaultName      = $kvName
        contentSafetyName = $csName
    })

    if (-not $SkipSmokeTest) {
        Write-Step 'Ejecutando smoke test'
        & $SmokeTest -ResourceGroup $ResourceGroup -ApimName $apimName -SubscriptionKey $subKey -Model $Model
        if ($LASTEXITCODE -ne 0) {
            Write-Warn2 "El smoke test reportó fallos. Revisa la salida anterior."
        }
    } else {
        Write-Info "Smoke test omitido (-SkipSmokeTest)."
    }

    Write-Step '¡Entorno listo!'
    Write-Host "  Ya puedes lanzar la demostración:" -ForegroundColor Green
    Write-Host "     python scripts/modelconn.py" -ForegroundColor White
    Write-Host "  Y generar tráfico sintético para la analítica:" -ForegroundColor Green
    Write-Host "     python tools/generate_events.py" -ForegroundColor White
    Write-Host "  Cuando termines, elimina todo con:" -ForegroundColor Green
    Write-Host "     ./bootstrap.ps1 remove" -ForegroundColor White
}

# ════════════════════════════════════════════════════════════════════════════
# REMOVE
# ════════════════════════════════════════════════════════════════════════════
function Invoke-Remove {
    Test-Prerequisites

    Write-Step 'Preparando eliminación'
    $state = Load-State

    if (-not $ResourceGroup) {
        if ($state -and $state.resourceGroup) { $ResourceGroup = $state.resourceGroup }
        else { $ResourceGroup = if ($Yes) { $DefaultRg } else { Read-WithDefault 'Resource Group a eliminar' $DefaultRg } }
    }
    if (-not $Location) {
        if ($state -and $state.location) { $Location = $state.location } else { $Location = $DefaultLocation }
    }

    $kvName = if ($state) { $state.keyVaultName } else { $null }
    $csName = if ($state) { $state.contentSafetyName } else { $null }
    $apimName = if ($state) { $state.apimName } else { $null }

    # Si no hay estado, intentar leer las salidas del despliegue (si el RG aún existe)
    if ((-not $kvName -or -not $csName -or -not $apimName)) {
        $exists = az group exists --name $ResourceGroup 2>$null
        if ($exists -eq 'true') {
            $oj = az deployment group show -g $ResourceGroup -n $DeployName --query 'properties.outputs' -o json 2>$null
            if ($oj) {
                $o = $oj | ConvertFrom-Json
                if (-not $kvName) { $kvName = $o.keyVaultName.value }
                if (-not $csName) { $csName = $o.contentSafetyName.value }
                if (-not $apimName) { $apimName = $o.apimName.value }
            }
        }
    }

    # Descubrimiento robusto: si tras state+outputs seguimos sin nombres (p.ej. un
    # 'create' que falló a medias no escribe state ni deja outputs), enumeramos los
    # recursos VIVOS del RG para capturar los nombres reales antes de borrarlo.
    if ((-not $kvName -or -not $csName -or -not $apimName)) {
        $exists = az group exists --name $ResourceGroup 2>$null
        if ($exists -eq 'true') {
            if (-not $apimName) {
                $apimName = az resource list -g $ResourceGroup --resource-type 'Microsoft.ApiManagement/service' --query '[0].name' -o tsv 2>$null
            }
            if (-not $kvName) {
                $kvName = az resource list -g $ResourceGroup --resource-type 'Microsoft.KeyVault/vaults' --query '[0].name' -o tsv 2>$null
            }
            if (-not $csName) {
                $csName = az resource list -g $ResourceGroup --resource-type 'Microsoft.CognitiveServices/accounts' --query '[0].name' -o tsv 2>$null
            }
        }
    }

    Write-Info "Resource Group    : $ResourceGroup"
    Write-Info "APIM a purgar     : $(if ($apimName) { $apimName } else { '(desconocido — se omite purga)' })"
    Write-Info "Key Vault a purgar: $(if ($kvName) { $kvName } else { '(desconocido — se omite purga)' })"
    Write-Info "Content Safety    : $(if ($csName) { $csName } else { '(desconocido — se omite purga)' })"

    if (-not $Yes) {
        $c = Read-Host "`n¿Eliminar el Resource Group y purgar los recursos? Esta acción es irreversible. (s/N)"
        if ($c -notmatch '^[sSyY]') { throw "Cancelado por el usuario." }
    }

    # Preservar la API key de Groq antes de tocar nada
    $groqKey = if ($GroqApiKey) { $GroqApiKey } else { Get-GroqKeyFromEnvFile }

    Write-Step "Eliminando Resource Group '$ResourceGroup'"
    $exists = az group exists --name $ResourceGroup 2>$null
    if ($exists -eq 'true') {
        Invoke-AzOrThrow -What 'eliminar el Resource Group' -Args @(
            'group', 'delete', '--name', $ResourceGroup, '--yes', '--output', 'none'
        )
        Write-Ok "Resource Group eliminado."
    } else {
        Write-Warn2 "El Resource Group '$ResourceGroup' no existe. Continuando con la purga."
    }

    Write-Step 'Purgando recursos en soft-delete'
    if ($apimName) {
        # APIM (SKU Developer/Consumption) queda en soft-delete tras borrar el RG y
        # bloquea recrear con el mismo nombre (ServiceAlreadyExistsInSoftDeletedState).
        # La purga solo es posible cuando la eliminación del servicio ha completado;
        # reintentamos unas cuantas veces mientras aparece en la lista de borrados.
        $purged = $false
        for ($i = 1; $i -le 10; $i++) {
            $deleted = az apim deletedservice list --query "[?name=='$apimName'] | [0].name" -o tsv 2>$null
            if ($deleted -eq $apimName) {
                az apim deletedservice purge --service-name $apimName --location $Location --output none 2>$null
                if ($LASTEXITCODE -eq 0) { $purged = $true; break }
            } elseif ($i -gt 1) {
                # Ya no está en la lista de borrados: o se purgó o nunca llegó a soft-delete.
                $purged = $true; break
            }
            Write-Info "Esperando a que APIM '$apimName' entre en soft-delete para purgarlo (intento $i/10)..."
            Start-Sleep -Seconds 30
        }
        if ($purged) { Write-Ok "APIM '$apimName' purgado (o no requería purga)." }
        else { Write-Warn2 "No se pudo purgar APIM '$apimName'. Púrgalo manualmente: az apim deletedservice purge --service-name $apimName --location $Location" }
    }
    if ($kvName) {
        az keyvault purge --name $kvName --location $Location --output none 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Ok "Key Vault '$kvName' purgado." }
        else { Write-Warn2 "No se pudo purgar el Key Vault '$kvName' (quizá no estaba en soft-delete o faltan permisos)." }
    }
    if ($csName) {
        az cognitiveservices account purge --name $csName --resource-group $ResourceGroup --location $Location --output none 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Ok "Content Safety '$csName' purgado." }
        else { Write-Warn2 "No se pudo purgar Content Safety '$csName' (quizá no estaba en soft-delete o faltan permisos)." }
    }

    # Barrida de seguridad: purga cualquier CS/KV en soft-delete asociado a este RG
    # que no se hubiera capturado por nombre (p.ej. restos de removes previos). Se
    # identifica por el resource id / vaultId, que contiene '/resourceGroups/<rg>/'.
    $rgToken = "/resourceGroups/$ResourceGroup/"
    $delCs = az cognitiveservices account list-deleted -o json 2>$null | ConvertFrom-Json
    foreach ($c in @($delCs)) {
        if ($c.id -and ($c.id -like "*$rgToken*") -and ($c.name -ne $csName)) {
            az cognitiveservices account purge --name $c.name --resource-group $ResourceGroup --location $Location --output none 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Ok "Content Safety '$($c.name)' purgado (barrida)." }
        }
    }
    $delKv = az keyvault list-deleted -o json 2>$null | ConvertFrom-Json
    foreach ($k in @($delKv)) {
        $vid = $k.properties.vaultId
        if ($vid -and ($vid -like "*$rgToken*") -and ($k.name -ne $kvName)) {
            $kvLoc = if ($k.properties.location) { $k.properties.location } else { $Location }
            az keyvault purge --name $k.name --location $kvLoc --output none 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Ok "Key Vault '$($k.name)' purgado (barrida)." }
        }
    }

    Write-Step 'Actualizando environment.env (preservando GROQ_API_KEY)'
    if ($groqKey) {
        Write-EnvFileGroqOnly -GroqKey $groqKey
        Write-Ok "environment.env conserva la API key de Groq ($(Mask $groqKey)); variables Azure vaciadas."
    } else {
        Write-Warn2 "No se encontró GROQ_API_KEY; environment.env no se ha modificado."
    }

    if (Test-Path $StateFile) { Remove-Item $StateFile -Force; Write-Info "Estado (.bootstrap-state.json) eliminado." }

    Write-Step 'Limpieza completada'
    Write-Host "  El entorno Azure ha sido eliminado. La API key de Groq se conserva." -ForegroundColor Green
    Write-Host "  Para volver a montarlo: ./bootstrap.ps1 create" -ForegroundColor White
}

# ─── Dispatcher ───────────────────────────────────────────────────────────────
try {
    switch ($Action) {
        'create' { Invoke-Create }
        'remove' { Invoke-Remove }
    }
} catch {
    Write-ErrX $_.Exception.Message
    exit 1
}
