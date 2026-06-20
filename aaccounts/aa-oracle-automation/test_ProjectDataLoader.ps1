$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'
Set-StrictMode -Version Latest

Import-Module util_Integration -Force  -DisableNameChecking

Initialize-Environment `
    -StorageAccountName 'saoraclehardy' `
    -ResourceGroupName  'rg-oracle-hardy' `
    -SubscriptionId     'Azure Solviasgroup.com / SoftwareOne'

$runId = New-RunId
Set-FlowInfo -FlowName 'ProjectDataLoader' -System 'Azure'

$endpoints = Get-EndpointConfig

Log-Info -Phase 'START' -Message "Project data load started" -Level 'INFO'

#--------------------------------------------------------------------------------------------
# retrieve current project lines from Dynamics (including internal projects with INT in name)
# -------------------------------------------------------------------------------------------
try {

    $sqlUrl = $endpoints.SqlServer.ConnectionString
    $sqlCred = $endpoints.SqlServer.Creds
    $plainPassword = [System.Net.NetworkCredential]::new("", $sqlCred.Password).Password
    $connectionString = $sqlUrl -replace '{p}', $plainPassword

    $intProjectQuery = @"
select
        left(concat( tsd.project_id ,'_', tsd.project_name ,'_',tsd.category), 150) as Value,
        concat (tsd.project_id  , '_', tsd.category ) as Description,
         0 as planned_effort ,
        '1900-01-01' as start_date,
        '1900-01-01' as end_date
from TimesheetData_INT_PROJ tsd
"@

$projectQuery = @"
WITH RankedData AS (
    SELECT
        rtrim(left(concat( tsd.project_id ,'_', tsd.project_name ,'_',tsd.cc, '_',tsd.customer_code,'_',tsd.customer_name), 150)) as Value,
        concat (tsd.project_id  , '_', tsd.category  , '_', tsd.position , '_', tsd.cc) as Description,
        tsd.planned_effort,
        tsd.start_date,
        tsd.end_date,
        -- Assign a unique rank (row number) within each group
        ROW_NUMBER() OVER (
            PARTITION BY tsd.project_id, tsd.customer_code, tsd.cc 
            ORDER BY tsd.planned_effort DESC, tsd.position ASC -- Use position as tie-breaker
        ) AS rn
    FROM
        TimesheetData tsd
    WHERE
        tsd.SALESUNITSYMBOL = 'h'
        AND tsd.SALESORDERLINESTATUS <> 4
        -- TODO: remove condition
        --AND project_id like  'AP0003%-001'
)
-- Select only the row with the highest planned_effort (rank 1)
SELECT 
    Value,
    Description,
    planned_effort,
    start_date,
    end_date
FROM
    RankedData
WHERE
    rn = 1;
"@

$dbRows = @()

$connection = New-Object System.Data.SqlClient.SqlConnection
$connection.ConnectionString = $connectionString
try {

    $connection.Open()
    $command = $connection.CreateCommand()
    $command.CommandText = $projectQuery
    $reader = $command.ExecuteReader()
    while ($reader.Read()) {
        $dbRows += [PSCustomObject]@{
            Value       = $reader["Value"]
            Description = $reader["Description"]
            planned_effort = $reader["planned_effort"]
            start_date = $reader["start_date"]
            end_date = $reader["end_date"]
        }
    }
    $reader.Close()


    Log-Info -Message "Project rows returned: $($dbRows.Count)" -Phase 'STEP' -Level 'INFO' -Records $dbRows.Count
    $command.CommandText = $intProjectQuery
    $reader = $command.ExecuteReader()
    while ($reader.Read()) {
        $dbRows += [PSCustomObject]@{
            Value       = $reader["Value"]
            Description = $reader["Description"]
            planned_effort = $reader["planned_effort"]
            start_date = $reader["start_date"]
            end_date = $reader["end_date"]
        }
    }
    $reader.Close()
    Log-Info -Message "Project rows returned including internal projects: $($dbRows.Count)" -Phase 'STEP' -Level 'INFO' -Records $dbRows.Count
 
} catch {
    Log-Error -Message "SQL query failed: $_" -Phase 'END' -Level 'ERROR' -status 'failed'
    throw
} finally {
    if ($connection.State -eq 'Open') { $connection.Close() }
}


# -----------------------------------------------
# retrieve complete set of lookup values from HCM
# -----------------------------------------------

###
$endpoint = $endpoints.Oracle.BaseUrl
[System.Management.Automation.PSCredential]$oraCreds = $endpoints.Oracle.Creds
$service = "fscmRestApi/resources/latest/valueSets/SOL_PROJECT_VALUES/child/values/"
$query = "?onlyData=true&fields=ValueId,Value,Description,EnabledFlag"
$requestUrl = $endpoint + $service + $query

try {
    $pair = "{0}:{1}" -f $oraCreds.UserName, $oraCreds.GetNetworkCredential().Password
    $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    $headers = @{ 
         Authorization = "Basic $encoded"
        "Content-Type" = "application/json; charset=utf-8" 
    }

    $appRows = @()
    $offset = 0
    $limit = 500  #need to do paging as there are 5000+ entries

    do {
        $url = "$requestURL&offset=$offset&limit=$limit"
        $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers  -ContentType "application/json" 

        if ($response.Count -gt 0) {
            $appRows += $response.items
            $offset += $limit
        }
    } while ($response.Count -gt 0)

    Write-Output "REST API call successful"
    Log-Info -Message "Project lookup values retrieved from Oracle HCM: $($appRows.Count)" -Phase 'STEP' -Level 'INFO' -Records $appRows.Count

    foreach ($row in $appRows) {
        if (-not $row.Value.Contains("_")) {Write-Output "Project lookup not loaded from MSD: $row"}
    }

    $FilteredAppRows = @()
    $FilteredAppRows = $appRows | Where-Object {
        $Parts = $_.Description.split('_')
        ($Parts.Length -gt 3 -or $_.Description -cmatch '^[A-Z]{2}\d{4}_INT$')
    }

    $DisabledAppRows = @()
    $DisabledAppRows = $appRows | Where-Object {
        $_.EnabledFlag -eq 'N'
    }

    $appRows = $FilteredAppRows
    #$appRows | Format-Table -AutoSize
    ## end of test block 
    #$appRows | Export-Csv -Path "c:\temp\approws.csv" -Encoding UTF8
    Log-Info -Message "Active Rows retrieved from Oracle" -Phase 'STEP' -Level 'INFO' -Records ($FilteredAppRows.Count - $DisabledAppRows.Count)

} catch {
    Log-Error -Message "REST API call failed: $_" -Phase 'END' -Level 'ERROR' -status 'FAILED'
    throw
}

# ----------------------------
# compare sets
# ----------------------------

$hashDT1     = @{}
$matchedKeys = @{}

# create hashtable with project id as key
foreach ($row in $appRows) {
    if (($row.Description -split '_').Length -eq 2) {
        # internal projects have different description format, use project id as key
        $key = ($row.Description -split '_')[0]
    } else {
        $key = ($row.Description -split '_')[0] + ($row.Description -split '_')[3]
    }
    $hashDT1[$key] = $row
    $matchedKeys[$key] = $false
}

$newRows = @()
$updatedRows = @()

#foreach ($row in $dtDB.Rows) {
foreach ($row in $dbRows) {
    if (($row.Description -split '_').Length -eq 2) {
        # internal projects have different description format, use project id as key
        $key = ($row.Description -split '_')[0]
    } else {
        $key = ($row.Description -split '_')[0] + ($row.Description -split '_')[3]
    }
    if ($hashDT1.ContainsKey($key)) {
         #Row exists, check if position_category are differnt
         # also check if the HRIS row is disabled, then enable it again
         if ($row.Description -ne $hashDT1[$key].Description -or $hashDT1[$key].EnabledFlag -eq 'N') {
            #$updatedRows += $row
            #capture the ValueId for running updates through REST
            $existingId = $hashDT1[$key].ValueId
            $existingValue = $hashDT1[$key].Value
            $existingDescription = $hashDT1[$key].Description
            $objToUpdate = $row | Select-Object *, 
                @{Name='ValueId'; Expression={$existingId}},
                @{Name='exValue'; Expression={$existingValue}},
                @{Name='exDescription'; Expression={$existingDescription}}

            #4/1/26 some (285) project descriptions have changed with proj_no/cc not matching the value, safeguarding here just by project
            if ($existingValue.split('_')[0]   -ne $row.Description.split('_')[0])  {
                Log-Warning -Message "Value mismatch for key $key, skipping update. HRIS Value='$($hashDT1[$key].Value)' DB '$($row.Value)' Description='$($row.Description)'" -Phase 'STEP' -Level 'WARNING'
                continue
            } 
            
            $updatedRows += $objToUpdate
            #
            }
        if ($hashDT1[$key].Value.EndsWith(" ") -and $hashDT1[$key].EnabledFlag -eq 'N') {
            Write-Output "HRIS Value='$($hashDT1[$key].Value)' DB '$($row.Value)' Enabled=$($hashDT1[$key].EnabledFlag)"
            # todo - move into updateValue list
            # for that one, disable the existing one and create a new one
            # add the old one to missing
            # add the new one to new
        }
        $matchedKeys[$key] = $true  # mark as found
     } else {
     # Row is new
        $newRows += $row
    }
}

# exclude EnabledFlag='N' rows from missing count
$missingRows = @($hashDT1.Keys | Where-Object { -not $matchedKeys[$_] -and ($hashDT1[$_].EnabledFlag -eq 'Y') } | ForEach-Object { $hashDT1[$_] })
$matchRows   = @($hashDT1.Keys | Where-Object {  $matchedKeys[$_] } | ForEach-Object { $hashDT1[$_] })


Write-Output "New rows: $($newRows.Count)"
Write-Output "Updated rows:  $($updatedRows.Count)"
Write-Output "Missing rows: $($missingRows.Count)"
Write-Output "Matched rows:  $($matchRows.Count)"

if ($newRows.Count -gt 0) {
    Set-BlobCsv -Container 'integrationdata' -BlobName "logs/projLinesNew_$(Get-Date -Format 'yyyyMMdd_HHmm').csv" -Data  $newRows  -Delimiter ';'
}
if ($missingRows.Count -gt 0) {
    Set-BlobCsv -Container 'integrationdata' -BlobName "logs/projLinesDel_$(Get-Date -Format 'yyyyMMdd_HHmm').csv" -Data  $missingRows  -Delimiter ';'
}
if ($updatedRows.Count -gt 0) {
    Set-BlobCsv -Container 'integrationdata' -BlobName "logs/projLinesUpd_$(Get-Date -Format 'yyyyMMdd_HHmm').csv" -Data  $updatedRows  -Delimiter ';'
}
    
# ----------------------------
# Guardrails - do not update HRIS if compare wasn't possible
# ----------------------------
if (($dbRows.Count -eq 0) -or ($appRows.Count -eq 0) -or ($missingRows.Count -gt 500)) {
    # somethings wrong, don't update HRIS
    Log-Warning -Message "Read and compare results don't look plausible, manual check required. Not updating HRIS" -Phase 'STEP' -Level 'WARNING'
    exit(1)
}   

# ----------------------------
# lookup values in HCM
# ----------------------------
$logEntries = [System.Collections.Generic.List[string]]::new()
$counter = 0
try {

    $headers = @{ 
        Authorization = "Basic $encoded"  
        "Content-Type" = "application/json; charset=utf-8" 
    }
    #
    # create new lookup values
    #

    #$rowsToProcess = $newRows[0..10]
    $rowsToProcess = $newRows
    foreach ($firstRow in $rowsToProcess) {

        $postURL = $endpoint + $service

        $jsonObj = @{ 
            "Value" = ($firstRow.Value) 
            "Description" = ($firstRow.Description)
            "EnabledFlag" = "Y"
            }

        $JsonBody = $jsonObj | ConvertTo-Json -Compress
        $BodyBytes = [System.Text.Encoding]::UTF8.GetBytes($JsonBody)
        
        # added try-catch to continue processing even if one row fails, and log the error
        try {
            $response = Invoke-WebRequest -Uri $postURL -Method POST -Headers $headers -Body $BodyBytes -UseBasicParsing
            $StatusCode = $response.StatusCode

            $response2 = $response | ConvertFrom-Json
            $logEntries.Add("status: $( $StatusCode) created ValueId:$($response2.ValueId) Value:$($response2.Value) Description:$($response2.Description) $($response2.CreationDate) $($response2.LastUpdatedBy)")
        } catch {
              Log-Error -Message "POST REST API call failed: $_" -Phase 'ITERATION' -Level 'ERROR' 
        }

        $counter += 1
        #sleep 5
    }

    #
    # update values if description has changed (meaning another subproject line now has max effort)
    #

    $rowsToProcess = $updatedRows
    foreach ($currentRow in $rowsToProcess) {

        $postUrl =  $endpoint + $service + $currentRow.ValueId
        $body1 = @{ 
            "Description" = ($currentRow.Description)
            "EnabledFlag" = "Y"
        } 
    
        $JsonBody = $body1 | ConvertTo-Json -Compress
        $BodyBytes = [System.Text.Encoding]::UTF8.GetBytes($JsonBody)

        try {
             $response = Invoke-WebRequest -Uri $postUrl -Method PATCH -Headers $headers -Body $BodyBytes -UseBasicParsing
             $StatusCode = $response.StatusCode
             $response2 = $response | ConvertFrom-Json
            $logEntries.Add("status: $( $StatusCode) updated ValueId:$($response2.ValueId) Value:$($response2.Value) Description:$($response2.Description) $($response2.CreationDate) $($response2.LastUpdatedBy)")
        } catch {
              Log-Error -Message "PATCH REST API call failed: $_" -Phase 'ITERATION' -Level 'ERROR' 
        }
     }

    #
    # disable lookup values in HRIS that have no match in Dynamics anymore
    #
    $rowsToProcess = $missingRows
    foreach ($currentRow in $rowsToProcess) {

        $postUrl =  $endpoint + $service + $currentRow.ValueId
        $body1 = @{ 
            "EnabledFlag" = 'N'
        } 
    
        $JsonBody = $body1 | ConvertTo-Json -Compress
        $BodyBytes = [System.Text.Encoding]::UTF8.GetBytes($JsonBody)
    

        try {
             $response = Invoke-WebRequest -Uri $postUrl -Method PATCH -Headers $headers -Body $BodyBytes -UseBasicParsing
             $StatusCode = $response.StatusCode
             $response2 = $response | ConvertFrom-Json
            $logEntries.Add("status: $( $StatusCode) disabled ValueId:$($response2.ValueId) Value:$($response2.Value) Description:$($response2.Description) $($response2.CreationDate) $($response2.LastUpdatedBy)")
        } catch {
              Log-Error -Message "PATCH REST API call failed: $_" -Phase 'ITERATION' -Level 'ERROR' 
        }
     }

    # store REST response log in blob for traceability
    if ($logEntries.Count -gt 0) {
        $fullTextContent = $logEntries -join "`r`n"
         Set-BlobFile `
        -Container "integrationdata" `
        -BlobName  "logs/ProjectSyncResult_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt" `
        -Content   ($logEntries -join "`r`n")
    }

    Log-Info -Phase 'END' `
         -Message "Project data load completed with $($newRows.Count) new, $($updatedRows.Count) updated, $($missingRows.Count) missing rows"  `
         -Status 'success' -DurationMs (Get-Elapsed) -Records $($newRows.Count)

} catch {
    Log-Error -Phase 'END' -Message "REST API to create lookup value failed: $_" -Level 'ERROR' -status 'failed'
    throw
}


} catch {
    Log-Error -Phase 'END' -Message "Failed: $_" -Level 'ERROR' -status 'failed'

    Write-Output "Message       : $($_.Exception.Message)"

    if ($_.InvocationInfo) {
        Write-Output "Script        : $($_.InvocationInfo.ScriptName)"
        Write-Output "Line Number   : $($_.InvocationInfo.ScriptLineNumber)"
        Write-Output "Position      : $($_.InvocationInfo.OffsetInLine)"
        Write-Output "Command       : $($_.InvocationInfo.Line)"
    }

    if ($_.ScriptStackTrace) {
        Write-Output "Stack Trace:"
        Write-Output $_.ScriptStackTrace
    }

    throw
}