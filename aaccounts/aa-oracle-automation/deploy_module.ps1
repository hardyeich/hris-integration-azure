# Deploy-Module.ps1 — run manually when util_Integration changes
$subId      = (Get-AzContext).Subscription.Id
$aa         = "aa-oracle-automation"
$rg         = "rg-oracle-hardy"
$env        = "ps7_plus_aztable"
$apiVersion = "2024-10-23"

Import-Module util_Integration -Force  -DisableNameChecking

Initialize-Environment `
    -StorageAccountName 'saoraclehardy' `
    -ResourceGroupName  'rg-oracle-hardy' `
    -SubscriptionId     'Azure Solviasgroup.com / SoftwareOne'

$runId = New-RunId
Set-FlowInfo -FlowName 'ReportDataLoader' -System 'Azure'

$endpoints = Get-EndpointConfig


$storageKey = $endpoints.Environment.StorageAccountKey
$ctx = New-AzStorageContext -StorageAccountName "saoraclehardy" `
                            -StorageAccountKey  $storageKey

Compress-Archive -Path ".\util_Integration\*" `
                 -DestinationPath ".\util_Integration.zip" -Force

Set-AzStorageBlobContent `
    -File      "util_Integration.zip" `
    -Container "integrationdata" `
    -Blob      "config/modules/util_Integration.zip" `
    -Context   $ctx -Force | Out-Null

$uri = New-AzStorageBlobSASToken `
           -Container  "integrationdata" `
           -Blob       "config/modules/util_Integration.zip" `
           -Permission r `
           -ExpiryTime (Get-Date).AddHours(1) `
           -Context    $ctx -FullUri

$modulePath = "/subscriptions/$subId/resourceGroups/$rg" +
              "/providers/Microsoft.Automation/automationAccounts/$aa" +
              "/runtimeEnvironments/$env/packages/util_Integration" +
              "?api-version=$apiVersion"

$result = Invoke-AzRestMethod -Method PUT -Path $modulePath -Payload (
    @{ properties = @{ contentLink = @{ uri = $uri } } } | ConvertTo-Json -Depth 5
)

if ($result.StatusCode -in 200,201,202) {
    Write-Output "✅ Module deployed to $env"
} else {
    Write-Warning "❌ Failed: $($result.StatusCode) $($result.Content)"
}