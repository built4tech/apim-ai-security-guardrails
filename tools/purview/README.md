# Purview Scripts

Scripts de PowerShell para administración y auditoría de Microsoft Purview Information Protection.

## Get-PurviewLabelsEncryption.ps1

Lista todas las etiquetas de sensibilidad (sensitivity labels) del tenant y analiza para cada una:

| Campo | Descripción |
|-------|-------------|
| **Cifrado** | Si la etiqueta aplica control de acceso con cifrado (encryption) |
| **Permiso EXTRACT** | Si el derecho EXTRACT está habilitado en la configuración de cifrado |
| **Copilot Grounding** | Si Microsoft 365 Copilot puede hacer grounding y leer el contenido protegido |

### Requisitos

- PowerShell 5.1+ o PowerShell 7+
- Módulo **ExchangeOnlineManagement** v3+:
  ```powershell
  Install-Module ExchangeOnlineManagement -Scope CurrentUser
  ```
- Permisos de **Compliance Administrator** o **Global Administrator**

### Uso

```powershell
# Ejecución básica (salida por consola)
.\Get-PurviewLabelsEncryption.ps1

# Exportar resultados a CSV
.\Get-PurviewLabelsEncryption.ps1 -ExportCsv

# Exportar a una ruta específica
.\Get-PurviewLabelsEncryption.ps1 -ExportCsv -CsvPath "C:\reports\labels.csv"
```

### ¿Por qué es importante el permiso EXTRACT?

Microsoft 365 Copilot necesita el derecho **EXTRACT** para poder:
- Leer el contenido de documentos protegidos con cifrado
- Incluir dicha información en sus respuestas (grounding)
- Resumir, buscar y referenciar documentos etiquetados

Si una etiqueta tiene cifrado **sin** el permiso EXTRACT, Copilot **no podrá** acceder al contenido de los documentos que usen esa etiqueta.
