@minLength(3)
@maxLength(24)
param environmentName string

param location string
param searchOperatorPrincipalId string
param applicationInsightsName string = ''
param logAnalyticsWorkspaceName string = ''
param monitoringReaderRoleAssignmentName string = ''
param modelName string
param modelVersion string
param modelSkuName string
param modelCapacity int
param apimBackendEnabled bool = false
param agentName string = ''
param agentVersion string = ''

var suffix = take(uniqueString(subscription().id, resourceGroup().id), 8)
var normalizedEnvironmentName = toLower(replace(environmentName, '-', ''))
var apimServiceName = take('apim-${normalizedEnvironmentName}-${suffix}', 50)
var languageAccountName = take('lang-${normalizedEnvironmentName}-${suffix}', 64)
var foundryAccountName = take('aif-${normalizedEnvironmentName}-${suffix}', 64)
var foundryProjectName = 'university-pii-demo'
var modelDeploymentName = 'university-demo-model'
var raiPolicyName = 'university-demo-base'
var searchServiceName = 'srch-${normalizedEnvironmentName}-${suffix}'
var searchIndexName = 'student-support-cases'
var searchReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1407120a-92aa-4202-b7e9-c0e197c71c8f')
var searchOperatorRoleIds = [
  subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
  subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8ebe5a00-799e-43f5-93ac-243d3dce84a7')
]

var cognitiveServicesUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'a97b65f3-24c7-4388-baec-2e87135dc908'
)
var cognitiveServicesOpenAIUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
)

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimServiceName
  location: location
  sku: {
    name: 'BasicV2'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: 'noreply@example.edu'
    publisherName: 'University PII Demo'
    publicNetworkAccess: 'Enabled'
  }
  tags: {
    application: 'university-pii-demo'
    environment: environmentName
  }
}

resource language 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: languageAccountName
  location: location
  kind: 'TextAnalytics'
  sku: {
    name: 'S'
  }
  properties: {
    customSubDomainName: languageAccountName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
  tags: {
    application: 'university-pii-demo'
    environment: environmentName
    purpose: 'pii-redaction'
  }
}

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: foundryAccountName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: foundryAccountName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
  tags: {
    application: 'university-pii-demo'
    environment: environmentName
  }
}

resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundry
  name: foundryProjectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'University PII Safety Demo'
    description: 'Foundry project for demonstrating PII redaction and guardrail enforcement.'
  }
}

resource raiPolicy 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01' = {
  parent: foundry
  name: raiPolicyName
  properties: {
    basePolicyName: 'Microsoft.DefaultV2'
    mode: 'Default'
    contentFilters: [
      {
        name: 'Hate'
        enabled: true
        blocking: true
        severityThreshold: 'Medium'
        source: 'Prompt'
      }
      {
        name: 'Hate'
        enabled: true
        blocking: true
        severityThreshold: 'Medium'
        source: 'Completion'
      }
      {
        name: 'Sexual'
        enabled: true
        blocking: true
        severityThreshold: 'Medium'
        source: 'Prompt'
      }
      {
        name: 'Sexual'
        enabled: true
        blocking: true
        severityThreshold: 'Medium'
        source: 'Completion'
      }
      {
        name: 'Violence'
        enabled: true
        blocking: true
        severityThreshold: 'Medium'
        source: 'Prompt'
      }
      {
        name: 'Violence'
        enabled: true
        blocking: true
        severityThreshold: 'Medium'
        source: 'Completion'
      }
      {
        name: 'SelfHarm'
        enabled: true
        blocking: true
        severityThreshold: 'Medium'
        source: 'Prompt'
      }
      {
        name: 'SelfHarm'
        enabled: true
        blocking: true
        severityThreshold: 'Medium'
        source: 'Completion'
      }
      {
        name: 'Jailbreak'
        enabled: true
        blocking: true
        source: 'Prompt'
      }
    ]
  }
}

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry
  name: modelDeploymentName
  sku: {
    name: modelSkuName
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
    raiPolicyName: raiPolicy.name
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

resource languageAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(language.id, apim.id, cognitiveServicesUserRoleId)
  scope: language
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesUserRoleId
  }
}

resource foundryModelAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, apim.id, cognitiveServicesOpenAIUserRoleId)
  scope: foundry
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesOpenAIUserRoleId
  }
}

resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: searchServiceName
  location: location
  sku: {
    name: 'basic'
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'Default'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
    semanticSearch: 'disabled'
  }
  tags: {
    application: 'university-pii-demo'
    environment: environmentName
    dataClassification: 'synthetic-only'
  }
}

resource searchOperatorAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleId in searchOperatorRoleIds: {
  name: guid(search.id, searchOperatorPrincipalId, roleId)
  scope: search
  properties: {
    principalId: searchOperatorPrincipalId
    principalType: 'User'
    roleDefinitionId: roleId
  }
}]

resource searchApimAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, apim.id, searchReaderRoleId)
  scope: search
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: searchReaderRoleId
  }
}

module agentResources './agent.bicep' = {
  name: 'university-pii-demo-agent-resources'
  params: {
    foundryAccountName: foundry.name
    foundryProjectName: foundryProject.name
    searchServiceName: search.name
    searchIndexName: searchIndexName
  }
}

module monitoring './monitoring.bicep' = {
  name: 'university-pii-demo-monitoring'
  params: {
    location: location
    foundryAccountName: foundry.name
    foundryProjectName: foundryProject.name
    applicationInsightsName: empty(applicationInsightsName) ? 'appi-${normalizedEnvironmentName}-${suffix}' : applicationInsightsName
    logAnalyticsWorkspaceName: empty(logAnalyticsWorkspaceName) ? 'log-${normalizedEnvironmentName}-${suffix}' : logAnalyticsWorkspaceName
    monitoringReaderRoleAssignmentName: monitoringReaderRoleAssignmentName
  }
}

module apimConfiguration './apim.bicep' = {
  name: 'university-pii-demo-apim'
  params: {
    apimServiceName: apim.name
    languageAccountName: language.name
    foundryAccountName: foundry.name
    foundryProjectName: foundryProject.name
    backendEnabled: apimBackendEnabled
    agentName: agentName
    agentVersion: agentVersion
  }
  dependsOn: [languageAccess]
}

output chatUrl string = apimConfiguration.outputs.chatUrl
output apimBackendConfigured bool = apimConfiguration.outputs.backendConfigured
output apimServiceName string = apim.name
output apimGatewayUrl string = apim.properties.gatewayUrl
output apimPrincipalId string = apim.identity.principalId
output apimAdvisorSubscriptionId string = apimConfiguration.outputs.subscriptionId
output languageAccountName string = language.name
output languageEndpoint string = 'https://${language.name}.cognitiveservices.azure.com/'
output foundryAccountName string = foundry.name
output foundryProjectName string = foundryProject.name
output foundryProjectEndpoint string = 'https://${foundry.name}.services.ai.azure.com/api/projects/${foundryProject.name}'
output applicationInsightsName string = monitoring.outputs.applicationInsightsName
output applicationInsightsId string = monitoring.outputs.applicationInsightsId
output logAnalyticsWorkspaceName string = monitoring.outputs.logAnalyticsWorkspaceName
output modelDeploymentName string = modelDeployment.name
output raiPolicyName string = raiPolicy.name
output searchServiceName string = search.name
output searchEndpoint string = 'https://${search.name}.search.windows.net'
output searchIndexName string = searchIndexName
