// ─────────────────────────────────────────────────────────────────────────────
// Módulo: API de GitHub Redirection + Named Values + Operaciones + Políticas
// Reproduce la configuración del entorno real:
//   API "github-redirection" (path vacío) con 4 operaciones POST, cada una con
//   su política (proxy simple, +Content Safety, +Prompt Shield, +ambas).
// Named Values:
//   - model-api-token  → referencia a Key Vault (secreto del token del proveedor)
//   - content-safety-endpoint / promptshield-endpoint → derivados del recurso CS
// ─────────────────────────────────────────────────────────────────────────────

@description('Nombre del servicio APIM existente.')
param apimName string

@description('Nombre de la API.')
param apiName string = 'github-redirection'

@description('Display name de la API.')
param apiDisplayName string = 'GitHub Redirection'

@description('Path de la API (vacío = raíz del gateway).')
param apiPath string = ''

@description('Identificador de secreto (versionless) del token del modelo en Key Vault.')
param modelApiTokenSecretUri string

@description('Endpoint base del recurso Content Safety (termina en "/").')
param contentSafetyEndpoint string

@description('api-version para el endpoint text:analyze de Content Safety.')
param contentSafetyApiVersion string = '2023-10-01'

@description('api-version para el endpoint text:shieldPrompt de Prompt Shield.')
param promptShieldApiVersion string = '2024-09-01'

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' existing = {
  name: apimName
}

// ─── Named Values ───────────────────────────────────────────────────────────

resource nvModelToken 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'model-api-token'
  properties: {
    displayName: 'model-api-token'
    secret: true
    keyVault: {
      secretIdentifier: modelApiTokenSecretUri
    }
  }
}

resource nvContentSafety 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'content-safety-endpoint'
  properties: {
    displayName: 'content-safety-endpoint'
    secret: false
    value: '${contentSafetyEndpoint}contentsafety/text:analyze?api-version=${contentSafetyApiVersion}'
  }
}

resource nvPromptShield 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'promptshield-endpoint'
  properties: {
    displayName: 'promptshield-endpoint'
    secret: false
    value: '${contentSafetyEndpoint}contentsafety/text:shieldPrompt?api-version=${promptShieldApiVersion}'
  }
}

// ─── API ─────────────────────────────────────────────────────────────────────

resource api 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: apiName
  properties: {
    displayName: apiDisplayName
    path: apiPath
    protocols: [
      'https'
    ]
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'Ocp-Apim-Subscription-Key'
      query: 'subscription-key'
    }
  }
}

// ─── Operaciones + Políticas ─────────────────────────────────────────────────
// Cada entrada define una operación POST y el fichero de política asociado.

var operations = [
  {
    name: 'github-redirection'
    displayName: 'GitHub Redirection'
    urlTemplate: '/gh-redirect'
    policyXml: loadTextContent('../policies/gh-redirect.xml')
  }
  {
    name: 'github-cs-redirection'
    displayName: 'GitHub CS Redirection'
    urlTemplate: '/gh-cs-redirect'
    policyXml: loadTextContent('../policies/gh-cs-redirect.xml')
  }
  {
    name: 'gh-ps-redirect'
    displayName: 'GitHub PS Redirection'
    urlTemplate: '/gh-ps-redirect'
    policyXml: loadTextContent('../policies/gh-ps-redirect.xml')
  }
  {
    name: 'github-cs-ps-redirection'
    displayName: 'GitHub CS & PS Redirection'
    urlTemplate: '/gh-cs-ps-redirect'
    policyXml: loadTextContent('../policies/gh-cs-ps-redirect.xml')
  }
]

resource apiOperations 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = [
  for op in operations: {
    parent: api
    name: op.name
    properties: {
      displayName: op.displayName
      method: 'POST'
      urlTemplate: op.urlTemplate
      responses: []
    }
  }
]

resource operationPolicies 'Microsoft.ApiManagement/service/apis/operations/policies@2023-05-01-preview' = [
  for (op, i) in operations: {
    parent: apiOperations[i]
    name: 'policy'
    properties: {
      format: 'rawxml'
      value: op.policyXml
    }
    dependsOn: [
      nvModelToken
      nvContentSafety
      nvPromptShield
    ]
  }
]

@description('Nombre de la API creada.')
output apiName string = api.name
