using 'main.bicep'

// ─── Parámetros de ejemplo ────────────────────────────────────────────────────
// Copia este fichero y ajusta los valores para tu entorno.
// El token del proveedor de modelo NO debe commitearse: pásalo por línea de comandos
// o variable de entorno segura (ver README).

param namePrefix = 'aisec'

param apimPublisherEmail = 'admin@example.com'
param apimPublisherName = 'My Organization'

param apimSkuName = 'Developer'
param apimCapacity = 1

param contentSafetySku = 'S0'

param logRetentionInDays = 30

// Recomendado: inyectar el token en despliegue en lugar de dejarlo aquí.
//   az deployment group create ... --parameters modelApiToken=$env:GROQ_API_KEY
// getSecret desde un Key Vault existente también es posible:
//   param modelApiToken = az.getSecret('<subId>','<rg>','<kvName>','<secretName>')
// Nota: en ficheros .bicepparam NO se usan decoradores (@secure va en main.bicep).
param modelApiToken = readEnvironmentVariable('GROQ_API_KEY', '')
