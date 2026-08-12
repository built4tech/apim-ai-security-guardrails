<#
.SYNOPSIS
    Lista las etiquetas de sensibilidad de Microsoft Purview y muestra si tienen
    cifrado (control de acceso) y si el permiso EXTRACT está habilitado para
    permitir grounding de Microsoft 365 Copilot.

.DESCRIPTION
    Este script se conecta al módulo de Security & Compliance de Exchange Online,
    obtiene todas las etiquetas de sensibilidad (sensitivity labels) y por cada una
    muestra:
      - Si tiene cifrado habilitado (control de acceso)
      - Si el derecho EXTRACT está concedido (necesario para que Copilot pueda
        leer y hacer grounding con la información protegida)

.NOTES
    Requisitos:
      - Módulo ExchangeOnlineManagement v3+ instalado
        Install-Module ExchangeOnlineManagement -Scope CurrentUser
      - Permisos de administrador de cumplimiento o administrador global
      - PowerShell 5.1+ o PowerShell 7+

.EXAMPLE
    .\Get-PurviewLabelsEncryption.ps1
    .\Get-PurviewLabelsEncryption.ps1 -ExportCsv
    .\Get-PurviewLabelsEncryption.ps1 -ExportCsv -CsvPath "C:\reports\labels.csv"
#>

[CmdletBinding()]
param(
    [switch]$ExportCsv,
    [string]$CsvPath = ".\PurviewLabels_Report.csv"
)

# ─────────────────────────────────────────────
# Colores para la salida en consola
# ─────────────────────────────────────────────
function Write-Status {
    param([string]$Message, [string]$Status, [ConsoleColor]$Color)
    Write-Host "  $Message : " -NoNewline
    Write-Host $Status -ForegroundColor $Color
}

# ─────────────────────────────────────────────
# 1. Verificar e importar módulo
# ─────────────────────────────────────────────
Write-Host "`n╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Purview Sensitivity Labels - Análisis de Cifrado y Permisos   ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

$moduleName = "ExchangeOnlineManagement"
if (-not (Get-Module -ListAvailable -Name $moduleName)) {
    Write-Host "[!] El módulo '$moduleName' no está instalado." -ForegroundColor Red
    Write-Host "    Instálalo con: Install-Module $moduleName -Scope CurrentUser" -ForegroundColor Yellow
    exit 1
}

Import-Module $moduleName -ErrorAction Stop
Write-Host "[✓] Módulo '$moduleName' cargado correctamente.`n" -ForegroundColor Green

# ─────────────────────────────────────────────
# 2. Conectar a Security & Compliance
# ─────────────────────────────────────────────
Write-Host "[*] Conectando a Security & Compliance Center..." -ForegroundColor Yellow
Write-Host "    (Se abrirá una ventana de autenticación si no hay sesión activa)`n" -ForegroundColor DarkGray

try {
    Connect-IPPSSession -ErrorAction Stop
    Write-Host "[✓] Conexión establecida con Security & Compliance Center.`n" -ForegroundColor Green
}
catch {
    Write-Host "[✗] Error al conectar: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    Asegúrate de tener permisos de Compliance Administrator." -ForegroundColor Yellow
    exit 1
}

# ─────────────────────────────────────────────
# 3. Obtener etiquetas de sensibilidad
# ─────────────────────────────────────────────
Write-Host "[*] Obteniendo etiquetas de sensibilidad...`n" -ForegroundColor Yellow

try {
    $labels = Get-Label -ErrorAction Stop | Sort-Object -Property Priority
}
catch {
    Write-Host "[✗] Error al obtener etiquetas: $($_.Exception.Message)" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    exit 1
}

if (-not $labels -or $labels.Count -eq 0) {
    Write-Host "[!] No se encontraron etiquetas de sensibilidad en el tenant.`n" -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    exit 0
}

Write-Host "[✓] Se encontraron $($labels.Count) etiqueta(s) de sensibilidad.`n" -ForegroundColor Green

# ─────────────────────────────────────────────
# 4. Analizar cada etiqueta
# ─────────────────────────────────────────────
$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$separator = "─" * 66

foreach ($label in $labels) {
    $isEncrypted      = $false
    $extractEnabled   = $false
    $rightsDetails    = "N/A"
    $copilotReady     = $false
    $parentName       = ""
    $protectionType   = ""
    $assignedUsers    = @()

    # Determinar etiqueta padre (si es sub-etiqueta)
    if ($label.ParentId) {
        $parent = $labels | Where-Object { $_.Guid -eq $label.ParentId }
        if ($parent) { $parentName = $parent.DisplayName }
    }

    # Parsear LabelActions (JSON) para detectar cifrado y derechos.
    # Get-Label almacena la configuración de cifrado dentro de LabelActions,
    # no como propiedades directas del objeto.
    if ($label.LabelActions) {
        $actions = $null
        try {
            $actionsRaw = $label.LabelActions
            if ($actionsRaw -is [string]) {
                $actions = $actionsRaw | ConvertFrom-Json
            } else {
                $actions = $actionsRaw | ForEach-Object {
                    if ($_ -is [string]) { $_ | ConvertFrom-Json } else { $_ }
                }
            }
        } catch {
            $actions = $null
        }

        if ($actions) {
            $encryptAction = $actions | Where-Object { $_.Type -eq "encrypt" }

            if ($encryptAction) {
                $settings = @{}
                foreach ($s in $encryptAction.Settings) {
                    $settings[$s.Key] = $s.Value
                }

                # Cifrado activo si existe la acción y no está deshabilitada
                $isDisabled = $settings["disabled"]
                if ($isDisabled -ne "true") {
                    $isEncrypted = $true
                }

                $protectionType = $settings["protectiontype"]

                # Protección definida por el usuario (Do Not Forward / Encrypt-Only)
                if ($protectionType -eq "userdefined") {
                    $rightsDetails = "Protección definida por el usuario (Do Not Forward / Encrypt-Only)"
                    $extractEnabled = $false
                }
                elseif ($settings["rightsdefinitions"]) {
                    # Parsear las definiciones de derechos (JSON anidado como string)
                    try {
                        $rightsDefs = $settings["rightsdefinitions"] | ConvertFrom-Json
                        $rightsEntries = @()
                        foreach ($rd in $rightsDefs) {
                            $identity = $rd.Identity
                            $rights   = $rd.Rights
                            $rightsEntries += "$identity : $rights"
                            $assignedUsers += [PSCustomObject]@{
                                Identity = $identity
                                Rights   = $rights
                            }

                            if ($rights -match "EXTRACT") {
                                $extractEnabled = $true
                            }
                        }
                        $rightsDetails = $rightsEntries -join "`n                          "
                    } catch {
                        $rightsDetails = $settings["rightsdefinitions"]
                        if ($rightsDetails -match "EXTRACT") {
                            $extractEnabled = $true
                        }
                    }
                }
            }
        }
    }

    # Copilot puede hacer grounding si:
    #  - No hay cifrado (sin restricciones), O
    #  - Hay cifrado pero EXTRACT está habilitado
    $copilotReady = (-not $isEncrypted) -or $extractEnabled

    # Construir resultado
    $result = [PSCustomObject]@{
        DisplayName       = $label.DisplayName
        Name              = $label.Name
        ParentLabel       = $parentName
        Priority          = $label.Priority
        Encryption        = if ($isEncrypted) { "Sí" } else { "No" }
        ExtractPermission = if (-not $isEncrypted) { "N/A (sin cifrado)" }
                            elseif ($extractEnabled) { "Habilitado" }
                            else { "No habilitado" }
        CopilotGrounding  = if ($copilotReady) { "✓ Compatible" } else { "✗ Bloqueado" }
        RightsDetails     = $rightsDetails
        ContentType       = ($label.ContentType -join ", ")
        LabelGuid         = $label.Guid
    }

    $results.Add($result)

    # Mostrar en consola
    Write-Host $separator -ForegroundColor DarkGray
    $indent = if ($parentName) { "  └─ " } else { "" }
    Write-Host "$indent🏷️  $($label.DisplayName)" -ForegroundColor White
    if ($parentName) {
        Write-Host "     Etiqueta padre  : $parentName" -ForegroundColor DarkGray
    }
    Write-Host "     Prioridad       : $($label.Priority)" -ForegroundColor DarkGray

    if ($isEncrypted) {
        Write-Status -Message "     Cifrado         " -Status "Sí (control de acceso activo)" -Color Red
    } else {
        Write-Status -Message "     Cifrado         " -Status "No" -Color Green
    }

    if (-not $isEncrypted) {
        Write-Status -Message "     Permiso EXTRACT " -Status "N/A (sin cifrado - acceso libre)" -Color Gray
    } elseif ($extractEnabled) {
        Write-Status -Message "     Permiso EXTRACT " -Status "Habilitado" -Color Green
    } else {
        Write-Status -Message "     Permiso EXTRACT " -Status "No habilitado" -Color Red
    }

    if ($copilotReady) {
        Write-Status -Message "     Copilot Ground. " -Status "✓ Compatible - Copilot puede leer contenido" -Color Green
    } else {
        Write-Status -Message "     Copilot Ground. " -Status "✗ Bloqueado - Copilot NO puede hacer grounding" -Color Red
    }

    if ($isEncrypted -and $rightsDetails -ne "N/A") {
        Write-Host "     Tipo protección : $protectionType" -ForegroundColor DarkGray
        if ($assignedUsers.Count -gt 0) {
            Write-Host "     Usuarios/Derechos:" -ForegroundColor DarkGray
            foreach ($u in $assignedUsers) {
                $hasExtract = if ($u.Rights -match "EXTRACT") { " ✓EXTRACT" } else { " ✗sin EXTRACT" }
                $extractColor = if ($u.Rights -match "EXTRACT") { "Green" } else { "Red" }
                Write-Host "       • $($u.Identity)" -NoNewline -ForegroundColor DarkGray
                Write-Host $hasExtract -ForegroundColor $extractColor
                Write-Host "         Derechos: $($u.Rights)" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "     Derechos        : $rightsDetails" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}

Write-Host $separator -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# 5. Resumen
# ─────────────────────────────────────────────
$totalLabels      = $results.Count
$encryptedCount   = ($results | Where-Object { $_.Encryption -eq "Sí" }).Count
$extractOkCount   = ($results | Where-Object { $_.ExtractPermission -eq "Habilitado" }).Count
$copilotOkCount   = ($results | Where-Object { $_.CopilotGrounding -like "*Compatible*" }).Count
$copilotBlockCount = ($results | Where-Object { $_.CopilotGrounding -like "*Bloqueado*" }).Count

Write-Host "`n╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                         RESUMEN                                ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Total etiquetas              : $($totalLabels.ToString().PadLeft(5))                          ║" -ForegroundColor White
Write-Host "║  Con cifrado                  : $($encryptedCount.ToString().PadLeft(5))                          ║" -ForegroundColor White
Write-Host "║  Cifradas con EXTRACT         : $($extractOkCount.ToString().PadLeft(5))                          ║" -ForegroundColor White
Write-Host "║  Compatibles con Copilot      : $($copilotOkCount.ToString().PadLeft(5))                          ║" -ForegroundColor $(if ($copilotOkCount -gt 0) { "Green" } else { "White" })
Write-Host "║  Bloqueadas para Copilot      : $($copilotBlockCount.ToString().PadLeft(5))                          ║" -ForegroundColor $(if ($copilotBlockCount -gt 0) { "Red" } else { "White" })
Write-Host "╚══════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

if ($copilotBlockCount -gt 0) {
    Write-Host "[⚠] Hay $copilotBlockCount etiqueta(s) que BLOQUEAN el grounding de Copilot." -ForegroundColor Yellow
    Write-Host "    Para habilitarlo, añade el derecho EXTRACT a los usuarios autorizados" -ForegroundColor Yellow
    Write-Host "    en la configuración de cifrado de cada etiqueta desde el portal de" -ForegroundColor Yellow
    Write-Host "    Microsoft Purview > Information Protection > Labels.`n" -ForegroundColor Yellow
}

# ─────────────────────────────────────────────
# 6. Exportar a CSV (opcional)
# ─────────────────────────────────────────────
if ($ExportCsv) {
    try {
        $results | Select-Object DisplayName, Name, ParentLabel, Priority, `
            Encryption, ExtractPermission, CopilotGrounding, RightsDetails, `
            ContentType, LabelGuid |
            Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

        Write-Host "[✓] Reporte exportado a: $CsvPath`n" -ForegroundColor Green
    }
    catch {
        Write-Host "[✗] Error al exportar CSV: $($_.Exception.Message)`n" -ForegroundColor Red
    }
}

# ─────────────────────────────────────────────
# 7. Desconectar sesión
# ─────────────────────────────────────────────
Write-Host "[*] Desconectando sesión..." -ForegroundColor DarkGray
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "[✓] Sesión cerrada correctamente.`n" -ForegroundColor Green
