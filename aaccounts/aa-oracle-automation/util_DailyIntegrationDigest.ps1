function Test-ManagedIdentityAvailable {
    try {
        $response = Invoke-RestMethod `
            -Method GET `
            -Uri "http://169.254.169.254/metadata/instance?api-version=2021-02-01" `
            -Headers @{ Metadata = "true" } `
            -TimeoutSec 1

        return $true
    }
    catch {
        return $false
    }
}


function Connect-AzSmart {
    if ($env:AUTOMATION_ASSET_ACCOUNTID -or (Test-ManagedIdentityAvailable)) {
        Connect-AzAccount -Identity
        return "ManagedIdentity"
    }
    else {
        Import-AzContext -Path "$HOME\.azure\context.json" | Out-Null
        return "DeviceCode"
    }
}

$WebhookUrl = 'https://default3d03a437167548e087b9da95a9dff8.55.environment.api.powerplatform.com:443/powerautomate/automations/direct/workflows/52e43951d9a543c9a4acbb799da5e6c1/triggers/manual/paths/invoke?api-version=1&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=IJzRg1V_mAZ5AkzJhVr5O1OBbwWjTlxT8XTO0HlFVnQ'


Import-Module AzTable 
$mode = Connect-AzSmart

$StorageAccountName = 'saoraclehardy'
$ResourceGroupName = 'rg-oracle-hardy' 
$SubscriptionId    = 'Azure Solviasgroup.com / SoftwareOne'
$ContainerName = "integrationdata"
$TableName = "IntegrationLogs"

# Use key-based context — works reliably in Azure Automation
if ($mode -eq "DeviceCode") {
    $config     = Get-Content "C:\Integration\AzureMigration\config\endpoints.json" -Raw | ConvertFrom-Json
    $StorageKey = $config.StorageAccountKey
} else {
    $StorageKey = (Get-AzAutomationVariable -Name 'StorageAccountKey' `
                                        -ErrorAction SilentlyContinue `
                                        -ResourceGroupName 'rg-oracle-hardy' -AutomationAccountName 'aa-oracle-automation').Value
}


$Ctx = New-AzStorageContext -StorageAccountName $StorageAccountName `
                            -StorageAccountKey  $StorageKey `
                            -WarningAction SilentlyContinue

$Table = (Get-AzStorageTable -Name $TableName -Context $Ctx -WarningAction SilentlyContinue).CloudTable


# ==========================================
# 2. DATEN ABRUFEN (Heute ab Mitternacht)
# ==========================================
$TodayMidnight = (Get-Date).Date.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
#if ($mode -eq "ManagedIdentity") { $Table = (Get-AzStorageTable -Name $TableName -Context $Ctx).CloudTable }
$Logs = Get-AzTableRow -Table $Table -CustomFilter "Timestamp ge datetime'$TodayMidnight'"


# ==========================================
# 3. HTML-LOG DATEI ERSTELLEN
# ==========================================
$LogFileName = "Log_$(Get-Date -Format 'yyyy-MM-dd_HHmm').html"
$LocalPath = "$env:TEMP\$LogFileName"

$HtmlHeader = @"
<style>
    body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; padding: 20px; color: #333; }
    table { border-collapse: collapse; width: 100%; margin-top: 20px; }
    th, td { border: 1px solid #ddd; padding: 12px; text-align: left; font-size: 14px; word-wrap: break-word; max-width: 400px; }
    th { background-color: #0078D4; color: white; }
    tr:nth-child(even) { background-color: #f9f9f9; }
    tr:hover { background-color: #f1f1f1; }
    
    /* NEW: Custom class for the START phase */
    /* Using !important ensures it overrides the alternating row colors and hover effects */
    tr.phase-start, tr.phase-start:nth-child(even), tr.phase-start:hover { 
        background-color: #d1e7dd !important; /* Soft green */
        color: #0f5132 !important;            /* Dark green text */
        font-weight: bold;
    }
</style>
<title>Integration Log - $(Get-Date -Format 'dd.MM.yyyy')</title>
<h2>Detailed Integration Logs - $(Get-Date -Format 'dd.MM.yyyy')</h2>
"@

# 1. Generate the HTML and save it to a variable INSTEAD of piping to Out-File
$rawHtml = $Logs | Select-Object @{Name="Time"; Expression={([datetime]$_.Timestamp).ToLocalTime().ToString("HH:mm:ss")}}, 
                   flowName, environment, level, phase, status, message, records, details | 
                   ConvertTo-Html -Head $HtmlHeader 

# 2. Use -replace to find rows with exactly <td>START</td> and inject our new CSS class
# PowerShell handles the array iteration automatically here.
$highlightedHtml = $rawHtml -replace '<tr>(.*?)<td>START</td>', '<tr class="phase-start">$1<td>START</td>'

# 3. Write the modified HTML to the file
$highlightedHtml | Out-File $LocalPath

# ==========================================
# 4. UPLOAD & SAS-LINK GENERIEREN
# ==========================================
$BlobPath = "dev-logs/$LogFileName"

# Upload der Datei
Set-AzStorageBlobContent -File $LocalPath -Container $ContainerName -Blob $BlobPath -Context $Ctx -Force | Out-Null

# Link generieren (User Delegation SAS, 7 Tage gültig)
$ExpiryTime = (Get-Date).AddDays(7)
$DownloadUrl = New-AzStorageBlobSASToken -Container $ContainerName -Blob $BlobPath -Permission r -ExpiryTime $ExpiryTime -Context $Ctx -FullUri

Write-Output "Generated secure download link: $DownloadUrl"
# ==========================================
# 5. ADAPTIVE CARD DATEN AUFBEREITEN (Wie bisher)
# ==========================================
$FlowSummaries = @()
$GroupedLogs = $Logs | Group-Object -Property flowId, flowName

foreach ($Group in $GroupedLogs) {
    $StartRec = $Group.Group | Sort-Object Timestamp | Select-Object -First 1
    $EndRec = $Group.Group | Where-Object { $_.phase -eq "END" } | Select-Object -First 1
    
    if (-not $EndRec) {
        Write-Warning "No END record found for flow $($StartRec.flowName)"
        $EndRec = [PSCustomObject]@{
            status = "unknown"
            durationMs = 0
            records = 0
        }
    }

    $status = if ($EndRec.PSObject.Properties['status']) { $EndRec.status } else { 'unknown' }
    $durationMs = if ($EndRec.PSObject.Properties['durationMs']) { $EndRec.durationMs } else { 0 }
    $records = if ($EndRec.PSObject.Properties['records']) { $EndRec.records } else { 0 }

    $FlowSummaries += [PSCustomObject]@{
        FlowName    = $StartRec.flowName
        Env         = if ($StartRec.environment) { $StartRec.environment } else { "TEST" }
        StartTime   = ([datetime]$StartRec.Timestamp).ToLocalTime()
        StatusIcon  = if ($status -match '(?i)error|failed') { "❌" } else { "✅" }
        Duration    = if ($EndRec.PSObject.Properties['durationMs']) { [math]::Round($EndRec.durationMs, 0) } else { '0' }
        Records     = if ($EndRec.PSObject.Properties['records']) { $EndRec.records } else { '0' }
        Warn        = @($Group.Group | Where-Object { $_.level -eq "WARNING" }).Count
        Err         = @($Group.Group | Where-Object { $_.level -eq "ERROR" }).Count
    }
}

$MaxRunsPerFlow = 5 # Change this to whatever limit you want

$FilteredSummaries = $FlowSummaries | 
    Group-Object -Property FlowName | 
    ForEach-Object {
        # Sort each flow's runs by time (newest first) and keep only the top X
        $_.Group | Sort-Object StartTime -Descending | Select-Object -First $MaxRunsPerFlow
    }

$SortedSummaries = $FilteredSummaries | Sort-Object FlowName, @{Expression="StartTime"; Descending=$true}| Select-Object -First 25

# ==========================================
# 6. ADAPTIVE CARD JSON BAUEN
# ==========================================
$CardBody = @(
    @{ type = "TextBlock"; text = "📊 **Daily Integration Overview**"; weight = "Bolder"; size = "Large" },
    @{
        type = "ColumnSet"; spacing = "Medium"
        columns = @(
            @{ type = "Column"; width = "6"; items = @( @{ type = "TextBlock"; text = "**Integration**"; size = "Small" } ) },
            @{ type = "Column"; width = "1"; items = @( @{ type = "TextBlock"; text = "**Stat**"; size = "Small"; horizontalAlignment = "Center" } ) },
            @{ type = "Column"; width = "1"; items = @( @{ type = "TextBlock"; text = "**Sec**"; size = "Small"; horizontalAlignment = "Right" } ) },
            @{ type = "Column"; width = "2"; items = @( @{ type = "TextBlock"; text = "**Rec**"; size = "Small"; horizontalAlignment = "Right" } ) },
            @{ type = "Column"; width = "1"; items = @( @{ type = "TextBlock"; text = "**Wrn**"; size = "Small"; horizontalAlignment = "Right" } ) },
            @{ type = "Column"; width = "1"; items = @( @{ type = "TextBlock"; text = "**Err**"; size = "Small"; horizontalAlignment = "Right" } ) }
        )
    }
)

foreach ($Row in $SortedSummaries) {
    $DisplayName = "$($Row.FlowName) [$($Row.Env)] [$($Row.StartTime.ToString("HH:mm"))]"
    $CardBody += @{
        type = "ColumnSet"; spacing = "Small"; separator = $true
        columns = @(
            @{ type = "Column"; width = "6"; items = @( @{ type = "TextBlock"; text = $DisplayName; size = "Small"; wrap = $true } ) },
            @{ type = "Column"; width = "1"; items = @( @{ type = "TextBlock"; text = $Row.StatusIcon; horizontalAlignment = "Center"; size = "Small" } ) },
            @{ type = "Column"; width = "1"; items = @( @{ type = "TextBlock"; text = "$($Row.Duration)s"; horizontalAlignment = "Right"; size = "Small" } ) },
            @{ type = "Column"; width = "2"; items = @( @{ type = "TextBlock"; text = "$($Row.Records)"; horizontalAlignment = "Right"; size = "Small" } ) },
            @{ type = "Column"; width = "1"; items = @( @{ type = "TextBlock"; text = "$($Row.Warn)"; horizontalAlignment = "Right"; size = "Small"; color = if($Row.Warn -gt 0){"Warning"}else{"Default"} } ) },
            @{ type = "Column"; width = "1"; items = @( @{ type = "TextBlock"; text = "$($Row.Err)"; horizontalAlignment = "Right"; size = "Small"; color = if($Row.Err -gt 0){"Attention"}else{"Default"} } ) }
        )
    }
}

# Payload mit dem neuen Button (Action) am Ende
$MessagePayload = @{
    type = "message"
    attachments = @( @{
        contentType = "application/vnd.microsoft.card.adaptive"
        content = @{
            '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
            type = "AdaptiveCard"; version = "1.4"
            body = $CardBody
            actions = @( @{
                type = "Action.OpenUrl"
                title = "📑 View Full HTML Log"
                url = $DownloadUrl
            } )
        }
    } )
}



<# $MessagePayload = @{
    type = "message"
    attachments = @( @{
        contentType = "application/vnd.microsoft.card.adaptive"
        content = @{
            '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
            type = "AdaptiveCard"; version = "1.4"
            body = $CardBody
        }
    } )
} #>

# Senden
$res = Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body ($MessagePayload | ConvertTo-Json -Depth 10) -ContentType "application/json"
#write-output "Message sent with status code: $($res.StatusCode)"
