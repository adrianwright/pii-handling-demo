targetScope = 'subscription'

@minLength(3)
@maxLength(24)
@description('The azd environment name used to name the resource group and resources.')
param environmentName string

@description('Primary Azure region for the demo resources.')
param location string

@description('Object ID of the developer who manages and seeds the Search index.')
param searchOperatorPrincipalId string

@description('App Insights resource and Foundry connection name. Empty uses an environment-derived name.')
param applicationInsightsName string = ''

@description('Log Analytics workspace name. Set to preserve a portal-created workspace; empty uses an environment-derived name.')
param logAnalyticsWorkspaceName string = ''

@description('Existing Monitoring Reader assignment GUID, if created in the portal. Empty generates a deterministic assignment name.')
param monitoringReaderRoleAssignmentName string = ''

@description('Model name from the Microsoft Foundry model catalog.')
param modelName string = 'gpt-5.6-luna'

@description('Pinned model version for a repeatable demo.')
param modelVersion string = '2026-07-09'

@description('Azure OpenAI deployment SKU.')
param modelSkuName string = 'GlobalStandard'

@minValue(1)
@description('Model capacity in thousands of tokens per minute.')
param modelCapacity int = 5

@description('Enable only after the pinned agent and all its guardrails have been verified.')
param apimBackendEnabled bool = false
param agentName string = ''
param agentVersion string = ''

var resourceGroupName = 'rg-${environmentName}'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: {
    application: 'university-pii-demo'
    environment: environmentName
    workload: 'agentic-pii-safety'
  }
}

module resources './resources.bicep' = {
  name: 'university-pii-demo-resources'
  scope: resourceGroup
  params: {
    environmentName: environmentName
    location: location
    searchOperatorPrincipalId: searchOperatorPrincipalId
    applicationInsightsName: applicationInsightsName
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    monitoringReaderRoleAssignmentName: monitoringReaderRoleAssignmentName
    modelName: modelName
    modelVersion: modelVersion
    modelSkuName: modelSkuName
    modelCapacity: modelCapacity
    apimBackendEnabled: apimBackendEnabled
    agentName: agentName
    agentVersion: agentVersion
  }
}

output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = resourceGroup.name
output APIM_SERVICE_NAME string = resources.outputs.apimServiceName
output APIM_GATEWAY_URL string = resources.outputs.apimGatewayUrl
output APIM_CHAT_URL string = resources.outputs.chatUrl
output APIM_BACKEND_CONFIGURED bool = resources.outputs.apimBackendConfigured
output APIM_PRINCIPAL_ID string = resources.outputs.apimPrincipalId
output APIM_ADVISOR_SUBSCRIPTION_ID string = resources.outputs.apimAdvisorSubscriptionId
output LANGUAGE_ACCOUNT_NAME string = resources.outputs.languageAccountName
output LANGUAGE_ENDPOINT string = resources.outputs.languageEndpoint
output AZURE_AI_ACCOUNT_NAME string = resources.outputs.foundryAccountName
output AZURE_AI_PROJECT_NAME string = resources.outputs.foundryProjectName
output AZURE_AI_PROJECT_ENDPOINT string = resources.outputs.foundryProjectEndpoint
output APPLICATIONINSIGHTS_NAME string = resources.outputs.applicationInsightsName
output APPLICATIONINSIGHTS_RESOURCE_ID string = resources.outputs.applicationInsightsId
output LOG_ANALYTICS_WORKSPACE_NAME string = resources.outputs.logAnalyticsWorkspaceName
output MODEL_DEPLOYMENT_NAME string = resources.outputs.modelDeploymentName
output RAI_POLICY_NAME string = resources.outputs.raiPolicyName
output AZURE_SEARCH_SERVICE_NAME string = resources.outputs.searchServiceName
output AZURE_SEARCH_ENDPOINT string = resources.outputs.searchEndpoint
output AZURE_SEARCH_INDEX_NAME string = resources.outputs.searchIndexName
