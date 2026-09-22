#Requires -Version 7
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
Push-Location (Split-Path $PSScriptRoot)
try {
    $config = azd env get-values --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read the azd environment.' }
    az deployment group create --name university-pii-demo-agent `
        --resource-group $config.AZURE_RESOURCE_GROUP `
        --template-file infra\agent.bicep `
        --parameters foundryAccountName=$($config.AZURE_AI_ACCOUNT_NAME) `
            foundryProjectName=$($config.AZURE_AI_PROJECT_NAME) `
            searchServiceName=$($config.AZURE_SEARCH_SERVICE_NAME) `
            searchIndexName=$($config.AZURE_SEARCH_INDEX_NAME) `
        --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) { throw 'Agent resource deployment failed; chat remains unchanged.' }
    & .\search\seed.ps1 -SearchEndpoint $config.AZURE_SEARCH_ENDPOINT -IndexName $config.AZURE_SEARCH_INDEX_NAME
    & "$PSScriptRoot\.venv\Scripts\python.exe" "$PSScriptRoot\deploy.py"
    if ($LASTEXITCODE -ne 0) { throw 'Agent registration failed; chat remains unchanged.' }
} finally {
    Pop-Location
}
