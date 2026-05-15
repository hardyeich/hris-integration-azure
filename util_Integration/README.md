New-ModuleManifest `
    -Path            "C:\Integration\AzureMigration\util_Integration\util_Integration.psd1" `
    -RootModule      "util_Integration.psm1" `
    -ModuleVersion   "1.0.0" `
    -Author          "Hardy Eich" `
    -Description     "Oracle HCM / D365 / AD Integration Utilities" `
    -PowerShellVersion "7.2" `
    -RequiredModules @('Az.Accounts', 'Az.Storage', 'AzTable') `
    -FunctionsToExport @(
        'Initialize-Environment',
        'Get-EndpointConfig',
        'Import-CsvMapping',
        'Clear-MappingCache',
        'New-RunId',
        'Get-RunId',
        'Get-Elapsed',
        'Set-FlowInfo',
        'Write-LogEntry',
        'Log-Info',
        'Log-Warning',
        'Log-Error',
        'Get-OicData',
        'Invoke-BulkLoad',
        'Connect-AzSmart',
        'Test-ManagedIdentityAvailable',
        'Get-BlobFile',
        'Get-BlobCsv',
        'Set-BlobFile',
        'Write-StagingLog'
    )

# Test
$moduleDest = "$HOME\Documents\PowerShell\Modules\util_Integration"
New-Item -ItemType Directory -Path $moduleDest -Force

Copy-Item "C:\Integration\AzureMigration\util_Integration\*" -Destination $moduleDest -Recurse -Force

# Verify
Get-Module util_Integration -ListAvailable

# compress for Azure upload
$zipPath = ".\util_Integration.zip"
Compress-Archive -Path "C:\Integration\AzureMigration\util_Integration\*" `
                 -DestinationPath $zipPath -Force


# usage examples
# Retrieve CSV from blob
$mapping = Get-BlobCsv -Container 'config' -BlobName 'mappings/TimeDetails.csv' -Delimiter ';'

# Retrieve raw file
$content = Get-BlobFile -Container 'config' -BlobName 'templates/email.html'

# Retrieve to local path
Get-BlobFile -Container 'exports' -BlobName 'results.csv' -LocalPath 'C:\Temp\results.csv'

# Upload file
Set-BlobFile -Container 'exports' -BlobName 'output.csv' -LocalPath 'C:\Temp\output.csv'

# Upload content directly
Set-BlobFile -Container 'logs' -BlobName 'summary.txt' -Content $summaryText

# upload CSV
Set-BlobCsv -Container 'logs' `
            -BlobName  "projLinesNew_$(Get-Date -Format 'yyyy-MM-dd').csv" `
            -Data      $newRows `
            -Delimiter ','

# Write staging log
Write-StagingLog -ProcessName 'KelioAbsenceSync' `
                 -Status      'SUCCESS' `
                 -Count       49 `
                 -Start       $flowStartTime `
                 -End         ([datetime]::UtcNow)

