targetScope = 'resourceGroup'

param foundryAccountName string
param foundryProjectName string
param searchServiceName string
param searchIndexName string = 'student-support-cases'

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryAccountName
}
resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: account
  name: foundryProjectName
}
resource search 'Microsoft.Search/searchServices@2025-05-01' existing = {
  name: searchServiceName
}

var readerRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1407120a-92aa-4202-b7e9-c0e197c71c8f')
// The native Search tool can use the account identity; retain project access too.
resource accountSearchReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, account.id, readerRole)
  scope: search
  properties: {
    principalId: account.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: readerRole
  }
}
resource projectSearchReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, project.id, readerRole)
  scope: search
  properties: {
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: readerRole
  }
}

// The native tool reads index schema as well as documents.
var serviceContributorRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
resource searchSchemaAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for isProject in [false, true]: {
  name: guid(search.id, isProject ? project.id : account.id, serviceContributorRole)
  scope: search
  properties: {
    principalId: isProject ? project.identity.principalId : account.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: serviceContributorRole
  }
}]

resource connection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: project
  name: searchIndexName
  properties: {
    category: 'CognitiveSearch'
    target: 'https://${search.name}.search.windows.net'
    authType: 'AAD'
    isSharedToAll: false
    metadata: {
      ApiType: 'Azure'
      ResourceId: search.id
    }
  }
}

var protectionCategories = [
  'Name Protection'
  'Email Protection'
  'Phone Number Protection'
  'Address Protection'
  'IP Address Protection'
  'Age Protection'
  'U.S. Social Security Number (SSN) Protection'
  'U.S. Driver\'s License Number Protection'
  'U.S. or U.K. Passport Number Protection'
  'U.S. Bank Account Number Protection'
  'International Banking Account Number (IBAN) Protection'
  'Credit card Protection'
]
var harms = flatten(map(['Hate', 'Sexual', 'Violence', 'Selfharm'], name => map(['Prompt', 'Completion'], source => {
  name: name
  enabled: true
  blocking: true
  severityThreshold: 'Medium'
  source: source
})))
var pii = flatten(map(protectionCategories, name => map(['Prompt', 'Completion'], source => {
  name: name
  enabled: true
  blocking: true
  source: source
})))
resource guardrail 'Microsoft.CognitiveServices/accounts/raiPolicies@2025-06-01' = {
  parent: account
  name: 'university-student-privacy'
  properties: {
    basePolicyName: 'Microsoft.DefaultV2'
    mode: 'Blocking'
    contentFilters: concat(harms, pii, [
      { name: 'Jailbreak', enabled: true, blocking: true, source: 'Prompt' }
      { name: 'Protected Material Text', enabled: true, blocking: true, source: 'Completion' }
      { name: 'Protected Material Code', enabled: true, blocking: true, source: 'Completion' }
    ])
  }
}

output connectionId string = connection.id
output guardrailName string = guardrail.name
