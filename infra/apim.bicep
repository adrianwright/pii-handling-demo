targetScope = 'resourceGroup'

param apimServiceName string
param languageAccountName string
param foundryAccountName string
param foundryProjectName string = 'university-pii-demo'

@description('Leave disabled until the pinned agent version has verified input and output guardrails.')
param backendEnabled bool = false

@maxLength(100)
@description('Server-owned Foundry agent name; never accepted from the caller.')
param agentName string = ''

@maxLength(20)
param agentVersion string = ''

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimServiceName
}

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryAccountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: foundry
  name: foundryProjectName
}

var canInvoke = backendEnabled && !empty(agentName) && !empty(agentVersion)
// Project Responses requires Foundry User (formerly Azure AI User), not endpoint-only Consumer.
var agentUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d')

resource agentAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (canInvoke) {
  name: guid(project.id, apim.id, agentUserRoleId)
  scope: project
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: agentUserRoleId
  }
}

var settings = {
  'pii-demo-language-endpoint': 'https://${languageAccountName}.cognitiveservices.azure.com'
  'pii-demo-foundry-endpoint': 'https://${foundryAccountName}.services.ai.azure.com/api/projects/${foundryProjectName}'
  'pii-demo-backend-enabled': canInvoke ? 'true' : 'false'
  'pii-demo-agent-name': empty(agentName) ? 'not-configured' : agentName
  'pii-demo-agent-version': empty(agentVersion) ? 'not-configured' : agentVersion
}

resource namedValues 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [for setting in items(settings): {
  parent: apim
  name: setting.key
  properties: {
    displayName: setting.key
    value: setting.value
    secret: false
    tags: ['university-pii-demo']
  }
}]

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'university-pii-demo'
  properties: {
    displayName: 'University PII Safety Demo'
    description: 'Synthetic-data-only gateway. Redaction is mandatory; Foundry is fail-closed until configured.'
    path: 'student-support'
    protocols: ['https']
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'Ocp-Apim-Subscription-Key'
      query: 'subscription-key'
    }
    type: 'http'
    apiRevision: '1'
  }
}

resource schema 'Microsoft.ApiManagement/service/schemas@2024-05-01' = {
  parent: apim
  name: 'university-pii-demo-request'
  properties: {
    schemaType: 'json'
    description: 'Strict synthetic demo input; only user text, no tools, instructions, history IDs, or bypass flags.'
    document: {
      value: loadTextContent('./apim/request.schema.json')
    }
  }
}

resource chat 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'chat'
  properties: {
    displayName: 'Chat (synthetic data only)'
    method: 'POST'
    urlTemplate: '/chat'
    description: 'Accept prompt OR up to five user messages, demo=true, and a supported scenarioId.'
    request: {
      representations: [
        { contentType: 'application/json' }
      ]
    }
    responses: []
  }
}

resource policy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('./apim/policy.xml')
  }
  dependsOn: [namedValues, schema, chat]
}

resource demoSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'university-pii-demo-local'
  properties: {
    displayName: 'University PII Demo - local server only'
    scope: api.id
    state: 'active'
    allowTracing: false
  }
}

resource diagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: api
  name: 'azuremonitor'
  properties: {
    loggerId: '${apim.id}/loggers/azuremonitor'
    logClientIp: false
    alwaysLog: null
    sampling: {
      samplingType: 'fixed'
      percentage: 0
    }
    frontend: {
      request: { headers: [], body: { bytes: 0 } }
      response: { headers: [], body: { bytes: 0 } }
    }
    backend: {
      request: { headers: [], body: { bytes: 0 } }
      response: { headers: [], body: { bytes: 0 } }
    }
    metrics: false
  }
}

output chatUrl string = '${apim.properties.gatewayUrl}/student-support/chat'
output subscriptionId string = demoSubscription.name
output backendConfigured bool = canInvoke
