param(
    [Parameter(Mandatory=$false)]
    [object]$WebhookData
)

# ── Inline utilities or replace with module import when ready ─────────────────
# . "$PSScriptRoot\util_Utilities.ps1"

# ── Guard - only run if triggered by webhook ──────────────────────────────────
if (-not $WebhookData) {
    Write-Output "No webhook data received - exiting"
    exit
}

# ── Parse incoming payload ────────────────────────────────────────────────────
try {
    #$entries = $WebhookData.RequestBody | ConvertFrom-Json
    # allow array and single object payloads for flexibility
    $parsed  = $WebhookData.RequestBody | ConvertFrom-Json
    $entries = if ($parsed -is [array]) { $parsed } else { @($parsed) }

    if ($null -eq $entries -or $entries.Count -eq 0) {
        Write-Warning "Empty or invalid payload"
        exit
    }
    Write-Output "Received $($entries.Count) log entries"
} catch {
    Write-Warning "Failed to parse webhook payload: $_"
    exit
}

# ── Connect to storage ────────────────────────────────────────────────────────
try {
    Connect-AzAccount -Identity | Out-Null
    Set-AzContext -SubscriptionId (Get-AutomationVariable -Name 'SubscriptionId') | Out-Null

    # More direct context creation
    $storageAccount = Get-AutomationVariable -Name 'StorageAccountName'
    $resourceGroup  = Get-AutomationVariable -Name 'StorageResourceGroup'
    $storageKey     = Get-AutomationVariable -Name 'StorageAccountKey' 

$ctx = New-AzStorageContext `
            -StorageAccountName $storageAccount `
            -StorageAccountKey  $storageKey `
            -WarningAction SilentlyContinue

    $table = (Get-AzStorageTable -Name 'integrationLogs' -Context $ctx  -WarningAction SilentlyContinue).CloudTable

    Write-Output "DEBUG: Storage connected, table = $($table.Name)"
} catch {
    Write-Warning "Storage connection failed: $_"
    Write-Output "DEBUG: Full error: $($_.Exception | Format-List * | Out-String)"
    exit
}

# ── Write entries ─────────────────────────────────────────────────────────────
$written = 0
$failed  = 0

foreach ($entry in $entries) {
    try {
        if (-not $entry.flowName -or -not $entry.flowId) {
            Write-Warning "Skipping entry - missing flowName or flowId"
            $failed++
            continue
        }

        $rowKey = "$($entry.flowId)_$([DateTime]::UtcNow.ToString('HHmmss.fff'))_$written"
        Write-Output "DEBUG: PartitionKey=$($entry.flowName) RowKey=$rowKey"

        $properties = @{
            #timestamp   = if ($entry.timestamp) { [string]$entry.timestamp } else { [DateTime]::UtcNow.ToString('o') }
            # Using ISO 8601 format for consistency and sorting in Azure Table Storage, otherwise format in table for incoming log is like 04/27/2026 17:00:55
            timestamp = if ($entry.timestamp) { ([DateTime]$entry.timestamp).ToUniversalTime().ToString('o')} else { [DateTime]::UtcNow.ToString('o')}
            flowId      = [string]$entry.flowId
            flowName    = [string]$entry.flowName
            environment = [string]($entry.environment ?? 'Unknown')
            system      = [string]($entry.system      ?? 'OIC')
            level       = [string]($entry.level       ?? 'INFO')
            phase       = [string]($entry.phase       ?? 'STEP')
            message     = [string]($entry.message     ?? '')
        }

        # TODO: probably good to look at
        # also need to add the filed to the list as missing right now
        if ($null -ne $entry.status -and $entry.status -ne '')     { $properties.status     = [string]$entry.status }
        if ($null -ne $entry.details -and $entry.details -ne '')   { $properties.details    = [string]$entry.details }
        if ($null -ne $entry.records)    { $properties.records    = [int]$entry.records }
        if ($null -ne $entry.success)    { $properties.success    = [int]$entry.success }
        if ($null -ne $entry.errors)     { $properties.errors     = [int]$entry.errors }
        if ($null -ne $entry.durationMs) { $properties.durationMs = [int]$entry.durationMs }



        # Try direct REST insert instead of Add-AzTableRow
        $uri = "$($ctx.TableEndPoint)integrationLogs"

        Add-AzTableRow -Table        $table `
                       -PartitionKey $entry.flowName `
                       -RowKey       $rowKey `
                       -Property     $properties | Out-Null

        $written++

    } catch {
        Write-Warning "Failed to write entry: $_"
        Write-Output "DEBUG: Exception type: $($_.Exception.GetType().FullName)"
        Write-Output "DEBUG: Inner exception: $($_.Exception.InnerException?.Message)"
        Write-Output "DEBUG: Full exception: $($_.Exception.ToString())"
        $failed++
    }
}

Write-Output "Done — written: $written, failed: $failed"