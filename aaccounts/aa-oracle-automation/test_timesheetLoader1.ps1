Import-Module util_Integration -Force  -DisableNameChecking

# Create hash-key for project lines
function Get-RowKey {
     param(
        [Parameter(Mandatory=$true)]
        [object]$row
    )
        return "$(($row.emp_id).Trim())_$(($row.cc).Trim())_$(($row.proj_no).Trim())_$(($row.pos_id).Trim())_$(($row.p_date.ToString('yyyy-MM-dd').Trim() ))"
}

 # read project lines for reporting from Timesheet_data for cost center matching and create lookup hash
 function Get-ProjectConfig {
      param(
        [Parameter (Mandatory = $true)]
        [String]$connectionString
        )

    # return project_cc/max hash table for match lookups
    $projectQuery = @"
    WITH RankedData AS (
    SELECT
        tsd.project_id, 
        tsd.category,
        tsd.position,
        tsd.cc,
        tsd.planned_effort,
        tsd.start_date,
        tsd.end_date,
        -- Assign a unique rank (row number) within each group
        ROW_NUMBER() OVER (
            PARTITION BY tsd.project_id, tsd.cc 
            ORDER BY tsd.planned_effort DESC, tsd.position ASC -- Use position as tie-breaker
        ) AS rn,
        MAX(tsd.planned_effort) OVER (
            PARTITION BY tsd.project_id
        ) AS ProjectMaxEffort
    FROM
        TimesheetData tsd
    WHERE
        tsd.SALESUNITSYMBOL = 'h'
        AND tsd.SALESORDERLINESTATUS <> 4
    )
    -- Select only the row with the highest planned_effort (rank 1)
    SELECT
       project_id,
       cc,
       category,
       position,
       planned_effort,
       start_date,
       end_date,
       CASE
        WHEN planned_effort = ProjectMaxEffort THEN 1
        ELSE 0
    END AS IsProjectMaxEffort
    FROM
       RankedData
    WHERE
       rn = 1;
"@

    try {
    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    $connection.Open()
    $command = $connection.CreateCommand()
    $command.CommandText = $projectQuery
    $reader = $command.ExecuteReader()
    $DataTable = New-Object System.Data.DataTable
    $DataTable.Load($reader)

    $ResultsArray = [System.Collections.ArrayList]::new() # Use ArrayList for faster appending

    $ResultsArray= $DataTable.Rows | ForEach-Object {
    [PSCustomObject]@{
        ProjectID = $_.project_id
        CC = $_.cc
        Effort = $_.planned_effort
        Category = $_.category
        Position = $_.position
        PlannedEffort = $_.planned_effort
        StartDate = $_.start_date
        EndDate = $_.end_date
        ProjectMax = $_.IsProjectMaxEffort
    }
}

    $reader.Close() # Must close the reader!

    $ProjectLinesHashMap = @{}
    # Hashmap has one entry per ProjectId_CostCenter and additionally one 
    # with ProjectId_max for the max effort across all project rows
    foreach ($Row in $ResultsArray) {
        $LookupKey = $Row.ProjectID.trim() + "_" + $Row.CC.Trim()
        $ProjectLinesHashMap[$LookupKey] = @{
            Effort = $Row.Effort
            Category = $Row.Category
            Position = $Row.Position
            PlannedEffort = $Row.PlannedEffort
            StartDate = $Row.StartDate
            EndDate = $Row.EndDate
            ProjectMax = $Row.ProjectMax
        }
        if ($Row.ProjectMax -eq 1) {
            # add max per project lookup key
            $LookupKey = $Row.ProjectID.trim() + "_max" 
            $ProjectLinesHashMap[$LookupKey] = @{
                Effort = $Row.Effort
                Category = $Row.Category
                Position = $Row.Position
                PlannedEffort = $Row.PlannedEffort
                StartDate = $Row.StartDate
                EndDate = $Row.EndDate
                ProjectMax = $Row.ProjectMax
            }
        }
    }
    
    return $ProjectLinesHashMap

    } catch {
        Write-LogError "SQL query failed: $_" 
        throw
    } finally {
        if ($connection.State -eq 'Open') { $connection.Close() }
    }
 }

# read non-billable project lines and create lookup hash
function Get-NBProjects {
      param(
        [Parameter (Mandatory = $true)]
        [String]$connectionString
        )

$internalProjectsQuery = @"
    select project_id || '_' || category as value,
    project_id
    from TimesheetData_INT_PROJ
"@
    try {

    $internalProjectsHashMap = @{}

    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    $connection.Open()
    $command = $connection.CreateCommand()
    $command.CommandText = $internalProjectsQuery
    $reader = $command.ExecuteReader()
    while ([bool]$reader.Read()) {
        $dbValue = $reader["value"]
        $dbProject = $reader["project_id"] 
        $internalProjectsHashMap[$dbValue]=$dbProject
    }
    $reader.Close()

    } catch {
        #Write-LogError "SQL query failed: $_" 
        throw
    } finally {
        if ($connection.State -eq 'Open') { $connection.Close() }
    }

    return $internalProjectsHashMap
}

# compare input date and archive data
function Get-ConsolidatedBulkUploadData {
    param(
        [Parameter(Mandatory=$true)]
        [System.Data.DataTable]$DataTable,

        [Parameter(Mandatory=$true)]
        [System.Data.DataTable]$ArchiveTable
    )

    # --- 2. Build fast lookup maps for archive and data ---
    $dataMap = @{}
    foreach ($row in $DataTable.Rows) {
        $key = Get-RowKey $row
        $dataMap[$key] = $row
    }

    $archiveMap = @{}
    foreach ($row in $ArchiveTable.Rows) {
        $key = Get-RowKey $row
        $archiveMap[$key] = $row
        }

    # --- 3. Output table with same schema ---
    $outputTable = $DataTable.Clone()   # copies schema only

    # --- 4. Iterate data rows: new rows + delta rows ---
    foreach ($key in $dataMap.Keys) {

        $dataRow = $dataMap[$key]

        if ($archiveMap.ContainsKey($key)) {
            $archRow = $archiveMap[$key]

            # delta?
            if ($dataRow.P_TIME_NUM -ne $archRow.P_TIME_NUM) {
                $deltaValue = $dataRow.P_TIME_NUM - $archRow.P_TIME_NUM

                $deltaRow = $outputTable.NewRow()
                $deltaRow.EMP_ID     = $dataRow.EMP_ID
                $deltaRow.CC         = $dataRow.CC
                $deltaRow.PROJ_NO    = $dataRow.PROJ_NO
                $deltaRow.P_DATE     = $dataRow.P_DATE
                $deltaRow.P_PERIOD   = $dataRow.P_PERIOD
                $deltaRow.POS_ID     = $dataRow.POS_ID
                $deltaRow.CATEGORY   = $dataRow.CATEGORY
                $deltaRow.P_TIME_NUM = $deltaValue
                $outputTable.Rows.Add($deltaRow)
            }
        }
        else {
            # new row → insert as-is
            $newRow = $outputTable.NewRow()
            $newRow.ItemArray = $dataRow.ItemArray.Clone()
            $outputTable.Rows.Add($newRow)
        }
    }

    # --- 5. Iterate archive rows: reversal rows for missing keys ---
    foreach ($key in $archiveMap.Keys) {
        if (-not $dataMap.ContainsKey($key)) {

            $archRow = $archiveMap[$key]

            if ($archRow.P_TIME_NUM -eq 0) {
                # skip zero lines, these happen when archive entries were already reversed
                continue
            }
            $revRow = $outputTable.NewRow()
            $revRow.EMP_ID     = $archRow.EMP_ID
            $revRow.CC         = $archRow.CC
            $revRow.PROJ_NO    = $archRow.PROJ_NO
            $revRow.P_DATE     = $archRow.P_DATE
            $revRow.P_PERIOD   = $archRow.P_PERIOD
            $revRow.POS_ID     = $archRow.POS_ID
            $revRow.CATEGORY   = $archRow.CATEGORY
            $revRow.P_TIME_NUM = -1 * $archRow.P_TIME_NUM
            $outputTable.Rows.Add($revRow)
        }
    }

    # , to tell PowerShell to return it as-is rather than unwrapping it into the pipeline and returning System.Object[]
    return ,$outputTable
}

# sum up values by key columns (e.g. for consolidation to monthly values)
function Compress-DataTable {
    param(
        [Parameter(Mandatory=$true)]
        [System.Data.DataTable]$DataTable,

        [Parameter(Mandatory=$true)]
        [string[]]$KeyColumns,

        [Parameter(Mandatory=$true)]
        [string]$ValueColumn,

        [string]$DateColumn = $null     # if set, snaps to first of month
    )

    $resultTable = $DataTable.Clone()
    $index       = @{}

    foreach ($row in $DataTable.Rows) {

        # ── Snap date to first of month if requested ──────────────────────────
        $snapDate = $null
        if ($DateColumn) {
            $d        = $row.$DateColumn
            $snapDate = [DateTime]::new($d.Year, $d.Month, 1)
        }

        # ── Build composite key ───────────────────────────────────────────────
        $keyParts = $KeyColumns | ForEach-Object { $row.$_ }
        if ($DateColumn) { $keyParts += $snapDate.ToString('yyyyMMdd') }
        $key = $keyParts -join '|'

        # ── Compress ──────────────────────────────────────────────────────────
        if ($index.ContainsKey($key)) {
            $index[$key][$ValueColumn] += $row.$ValueColumn
        }
        else {
            $newRow           = $resultTable.NewRow()
            $newRow.ItemArray = $row.ItemArray
            if ($DateColumn) { $newRow.$DateColumn = $snapDate }
            $resultTable.Rows.Add($newRow)
            $index[$key] = $newRow
        }
    }
    # , to tell PowerShell to return it as-is rather than unwrapping it into the pipeline and returning System.Object[]
    return ,$resultTable
}

# normalize raw input row: split project number, resolve employee id and cost center, derive period, etc.
# Returns normalized object with additional _Valid flag for validity of resolution steps
function ConvertTo-NormalizedRow {
    param([PSCustomObject]$Row, $AutoIdMap, $CostCenterMap)

    # ── Project parts — split on '_' ──────────────────────────────────────────
    $projParts   = $Row.Project -split '_'
    $projNo      = $projParts[0]
    $projSuffix  = if ($projParts.Count -gt 1) { $projParts[1] } else { '' }
    $category    = if ($projParts.Count -gt 3) { $projParts[1] } else { '' }
    $position    = if ($projParts.Count -gt 3) { $projParts[2] } else { '' }
    $projCc      = if ($projParts.Count -gt 3) { $projParts[3] } else { '' }

    # ── Date and period ───────────────────────────────────────────────────────
    $date   = [datetime]$Row.Date.Substring(0, 19)
    $period = $date.ToString('yyyyMM')

    # ── Duration — round to 2 decimals ────────────────────────────────────────
    $duration = [math]::Round([decimal]$Row.Duration, 2)

    # ── Resolve EMP_ID ────────────────────────────────────────────────────────
    $empId = Resolve-EmpId -EmpId        $Row.'User Name' `
                           -PersonNumber $Row.'Person Number' `
                           -AutoIdMap    $AutoIdMap

    # ── Resolve Cost Center ───────────────────────────────────────────────────
    $cc = Resolve-CostCenter -OverridenCC   $Row.'Overriden Cost Center' `
                             -Department    $Row.Department `
                             -CostCenterMap $CostCenterMap

    return [PSCustomObject]@{
        EMP_ID      = $empId
        CC          = $cc
        PROJ_NO     = $projNo
        PROJ_SUFFIX = $projSuffix
        PROJ_CC     = $projCc
        CATEGORY    = $category
        POSITION    = $position
        P_DATE      = $date
        P_PERIOD    = $period
        P_TIME_NUM  = $duration
        POS_ID      = $position
        _PersonNo   = $Row.'Person Number'
        _RawProject = $Row.Project
        _Valid      = ($empId -ne $null -and $cc -ne $null)
    }
}

# ── Step 2: Classify ──────────────────────────────────────────────────────────
function Get-RowCategory {
    param(
        [PSCustomObject]$NormalizedRow,
        [hashtable]$InternalProjectsHash
    )

    # Internal: project in list AND suffix is INT
    if ($InternalProjectsHash.ContainsKey($NormalizedRow._RawProject) -or $InternalProjectsHash.ContainsKey($NormalizedRow.PROJ_NO + "_INT")) {
        return 'Internal'
    }
    return 'External'
}

# ── Step 3: EMP_ID and Cost Center resolvers ──────────────────────────────────
function Resolve-EmpId {
    param(
        [string]$EmpId,
        [string]$PersonNumber,
        $AutoIdMap
    )

    $pattern = "^[A-Z]{3,7}[0-9]{1,5}$"

    if ($EmpId -match $pattern)    { return $EmpId }
    if ($EmpId -in @('BMETZR'))    { return $EmpId }

    # Try mapping by person number
<#     $mapped = $AutoIdMap | 
              Where-Object { $_.PersonNumber -eq $PersonNumber -and $_.Auto_ERP_Id } |
              Select-Object -First 1

    if ($mapped) { return $mapped.Auto_ERP_Id }
 #>
    $mapped = $AutoIdMap | 
              Where-Object { $_.PERSON_NUMBER -eq $PersonNumber -and $_.SOL_ERP_MSD } |
              Select-Object -First 1

    if ($mapped) { return $mapped.SOL_ERP_MSD }
    return $null
}

function Resolve-CostCenter {
    param(
        [string]$OverridenCC,
        [string]$Department,
        $CostCenterMap
    )

    # ── Fix 1: detect Oracle fusion IDs in override field ────────────────────
    $override = ($OverridenCC -split ' ')[0]
    if ($override.Length -gt 7) {
        Log-Warning -Message "Oracle ID in override CC — ignored" `
                    -Details "Value: $override"
        $override = $null   # drop override, fall through to department
    }

    $cc = if (-not [string]::IsNullOrWhiteSpace($override)) {
        $override
    } else {
        ($Department -split ' ')[0]
    }

    if ($cc -match '^\d+$') { return $cc }

    $mapped = $CostCenterMap |
              Where-Object { $_.Type -eq 'CostCenter' -and $_.Orcl -eq $cc } |
              Select-Object -First 1

    if ($mapped) { return $mapped.Msd }

    return $null
}

function Resolve-ExternalRow {
    param(
        [PSCustomObject]$NormalizedRow,
        [hashtable]$ProjectsHash
    )

    # No proj_cc — no adjustment needed
    if ([string]::IsNullOrEmpty($NormalizedRow.PROJ_CC)) {
        return $NormalizedRow
    }

    # CC matches proj_cc — no adjustment needed
    if ($NormalizedRow.CC -eq $NormalizedRow.PROJ_CC) {
        return $NormalizedRow
    }

    # CC mismatch — try lookup
    $lookupKey    = "$($NormalizedRow.PROJ_NO)_$($NormalizedRow.CC)"
    $lookupKeyMax = "$($NormalizedRow.PROJ_NO)_max"

    if ($ProjectsHash.ContainsKey($lookupKey)) {
        $projectLine = $ProjectsHash[$lookupKey]
<#         Log-Info -Phase 'STEP' -Message "CC mismatch — adjusted from lookup" `
                 -Details "$($NormalizedRow.EMP_ID) | $($NormalizedRow.PROJ_NO) | pos $($NormalizedRow.POSITION) → $($projectLine.Position)" #>
        $NormalizedRow.POSITION = $projectLine.Position
        $NormalizedRow.CATEGORY = $projectLine.Category
        return $NormalizedRow
    }

    if ($ProjectsHash.ContainsKey($lookupKeyMax)) {
        $projectLine = $ProjectsHash[$lookupKeyMax]
<#         Log-Info -Phase 'STEP' -Message "CC mismatch — adjusted from max lookup" `
                 -Details "$($NormalizedRow.EMP_ID) | $($NormalizedRow.PROJ_NO) | pos $($NormalizedRow.POSITION) → $($projectLine.Position)" #>
        $NormalizedRow.POSITION = $projectLine.Position
        $NormalizedRow.CATEGORY = $projectLine.Category
        return $NormalizedRow
    }

    # Not found at all — exclude row
    Log-Info -Phase 'STEP' -Message "Project not found — row excluded" `
             -Details "$($NormalizedRow.PROJ_NO)"
    return $null   # null = exclude
}
<# 
Retrieve, process and load timesheet data from Oracle HCM to Azure SQL DB. The script performs the following steps:
1. Initializes the environment and logging context.
2. Retrieves timesheet data from OIC.
3. Loads cost center and autoid mapping data from blob storage.
4. Prepares the SQL connection string.
5. Retrieves project configuration from the database for lookups.
6. Normalizes the raw data, classifies rows into internal/external, and resolves project lines for external rows.
7. Compresses the data by summing up hours for identical keys.
8. Retrieves archived data from the database for comparison.
9. Compares the new data with the archive to identify new, changed, and removed rows
10. Bulk inserts the non-billable (internal) rows into a staging table, after deleting existing rows for the relevant period.
11. Bulk inserts the delta rows for billable (external) projects into the main table.
 #>


Initialize-Environment `
    -StorageAccountName 'saoraclehardy' `
    -ResourceGroupName  'rg-oracle-hardy' `
    -SubscriptionId     'Azure Solviasgroup.com / SoftwareOne'

$runId = New-RunId
Set-FlowInfo -FlowName 'TimesheetLoader' -System 'Azure'

$endpoints = Get-EndpointConfig

$startTime = ([datetime]::UtcNow) 
Log-Info -Phase 'START' -Message "TimesheetLoader run started" -RunId $runId
try {

    # get Oracle extract output via OIC
     $res= Get-OicData -Flow  "TimeCardDayReport" `
                -BIP         'Y' `
                -SearchLatest 'Y' `
                -BaseUrl     $endpoints.OIC.BaseUrl `
                -Credentials $endpoints.OIC.Creds `
                -OutputMode  'Memory'   
 
<#     $overrideData = Import-Csv  "C:\Integration\AzureMigration\scratch\Oracle to Timesheet ERP-20260517.csv" -Delimiter ',' -Encoding UTF8
    $overrideData = Import-Csv  "C:\Integration\Production\sftpDownloads\Timesheets\Oracle to Timesheet ERP-20260518.csv" -Delimiter ',' -Encoding UTF8
    $res = @{
        Data     = $overrideData
        Manifest = "C:\Integration\AzureMigration\scratch\Oracle to Timesheet ERP-20260517.csv"
        Count    = $overrideData.Count
    }
 #>   
    Log-Info -Phase 'STEP' -Message "OIC data retrieval result: $($res.count) records"  
 
    # read cost center mapping from blob storage and AutoId mapping from BIP report  
    $res1 = Get-OicData -Flow  "EmployeeDataReport" `
                -BIP         'Y' `
                -SearchLatest 'Y' `
                -BaseUrl     $endpoints.OIC.BaseUrl `
                -Credentials $endpoints.OIC.Creds `
                -OutputMode  'Memory'  

    #$res1.Data | Select-Object Person_Number, Username, FTE, Department, Location, Sol_erp_msd -First 10 | Format-Table -AutoSize
    $autoIdMap = $res1.Data | Select-Object -Property Person_Number, Username, Sol_erp_msd

    $costCenterMap = Get-BlobCsv -Container 'integrationdata' -BlobName 'config/leccMapping.csv' -Delimiter ';'
    # $autoIdMap = Get-BlobCsv -Container 'integrationdata' -BlobName 'config/ERPUserMapping.csv' -Delimiter ';'

    # prepare SQL connection string
    $sqlUrl = $endpoints.SqlServer.ConnectionString
    $sqlCred = $endpoints.SqlServer.Creds
    $plainPassword = [System.Net.NetworkCredential]::new("", $sqlCred.Password).Password
    $connectionString = $sqlUrl -replace '{p}', $plainPassword

    # get the current project line configuration from D365 for lookups
    $projectsHash = Get-ProjectConfig -connectionString $connectionString
    Log-Info -Phase 'STEP' -Message  "project lookups loaded" -records $projectsHash.count
    $InternalProjectsHash = Get-NBProjects -connectionString $connectionString
    Log-Info -Phase 'STEP' -Message "internal project lookups loaded" -records $InternalProjectsHash.count

    $csvData = $res.Data
    Log-Info -Phase 'STEP' -Message "Read CSV" -Records $csvData.Count
    
    $csvData = $csvData | ForEach-Object {
        [PSCustomObject]@{
            'Person Number'         = $_.PERSON_NUMBER
            'User Name'             = $_.USER_NAME
            'Project'               = $_.PROJECT
            'Date'                  = $_.DATE
            'Duration'              = $_.DURATION
            'Department'            = $_.DEPARTMENT
            'Overriden Cost Center' = $_.OVERRIDEN_COST_CENTER
        }
    }

    $csvData | Select-Object -First 10 | Format-Table -Autosize

    $skipped  = 0
    $internal = 0
    $external = 0

    # commercial projects DataTable
    $dataTable = New-Object System.Data.DataTable "BulkUploadData"
    $dataTable.Columns.Add("EMP_ID", [string])   | Out-Null
    $dataTable.Columns.Add("CC", [string])       | Out-Null
    $dataTable.Columns.Add("PROJ_NO", [string])  | Out-Null
    $dataTable.Columns.Add("P_DATE", [datetime]) | Out-Null
    $dataTable.Columns.Add("P_PERIOD", [string]) | Out-Null
    $dataTable.Columns.Add("P_TIME_NUM", [decimal]) | Out-Null
    $dataTable.Columns.Add("POS_ID", [string])   | Out-Null
    $dataTable.Columns.Add("CATEGORY", [string]) | Out-Null

    # non-billable project lines go to another target table
    $NBdataTable = $dataTable.Clone()

    foreach ($row in $csvData) {

        $norm = ConvertTo-NormalizedRow -Row $row `
                                        -AutoIdMap     $autoIdMap `
                                        -CostCenterMap $costCenterMap

        if (-not $norm._Valid) {
            Log-Warning -Message "Row skipped — invalid EMP_ID or CC" `
                        -Details "$($row."Person Number") | $($row.Project) $($row.Date)"
            $skipped++
            continue
        }

        $category = Get-RowCategory -NormalizedRow    $norm `
                                    -InternalProjects $InternalProjectsHash

        switch ($category) {
            'Internal' {
                $newRow            = $NBdataTable.NewRow()
                $newRow.EMP_ID     = $norm.EMP_ID
                $newRow.CC         = $norm.CC
                $newRow.PROJ_NO    = $norm.PROJ_NO
                $newRow.P_DATE     = $norm.P_DATE
                $newRow.P_PERIOD   = $norm.P_PERIOD
                $newRow.P_TIME_NUM = $norm.P_TIME_NUM
                $NBdataTable.Rows.Add($newRow)
                $internal++
            }
            'External' {
                
                $resolved = Resolve-ExternalRow -NormalizedRow $norm `
                                                -ProjectsHash  $projectsHash
                if (-not $resolved) { $skipped++; continue }

                $newRow            = $dataTable.NewRow()
                $newRow.EMP_ID     = $resolved.EMP_ID
                $newRow.CC         = $resolved.CC
                $newRow.PROJ_NO    = $resolved.PROJ_NO
                $newRow.P_DATE     = $resolved.P_DATE
                $newRow.P_PERIOD   = $resolved.P_PERIOD
                $newRow.P_TIME_NUM = $resolved.P_TIME_NUM
                $newRow.POS_ID     = $resolved.POSITION
                $newRow.CATEGORY   = $resolved.CATEGORY
                $dataTable.Rows.Add($newRow)
                $external++
            }
        }
    }

    Log-Info -Phase 'SUMMARY' -Message "Classification complete" `
            -Records ($internal + $external) `
            -Details "Internal: $internal | External: $external | Skipped: $skipped"


    # With distinct (duplicates in my version of extract run)
    $distinctColumns = @('EMP_ID', 'CC', 'PROJ_NO', 'P_DATE', 
                        'P_PERIOD', 'P_TIME_NUM', 'POS_ID', 'CATEGORY')
    $cleanTable  = $dataTable.DefaultView.ToTable($true, [string[]]$distinctColumns)
    # added POS_ID to compression keys to not merge entries with different positions
    $dataTable   = Compress-DataTable -DataTable $cleanTable `
                                    -KeyColumns  @('EMP_ID', 'CC', 'PROJ_NO','POS_ID') `
                                    -ValueColumn 'P_TIME_NUM' `
                                    -DateColumn  'P_DATE'

    Log-Info -Phase 'STEP' -Message "External compression complete" -Records $dataTable.Rows.Count
    # Without distinct
    $NBdataTable = Compress-DataTable -DataTable   $NBdataTable `
                                    -KeyColumns  @('EMP_ID', 'CC', 'PROJ_NO') `
                                    -ValueColumn 'P_TIME_NUM' `
                                    -DateColumn  'P_DATE' 

                                  
    Log-Info -Phase 'STEP' -Message "Internal compression complete" -Records $NBdataTable.Rows.Count

    $minDate = $dataTable.Compute("MIN(p_date)", "")
    Log-Info -Message "get archive back to $($minDate)" -Phase 'STEP' -Level 'INFO'

    $transcation = $null
    try {
    $archive = @"
select emp_id, cc, proj_no, p_date, p_period, sum(p_time_num) as p_time_num, pos_id, category 
from ProjTimeDataTS_archive where p_date >= @minDate group by emp_id, cc, proj_no, p_date, p_period, pos_id, category
"@

    $connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    $connection.Open()
    $command1 = New-Object System.Data.SqlClient.SqlCommand($archive, $connection)
    # TODO - could override to use begin of previous month
    $command1.Parameters.AddWithValue("@minDate", $minDate) | Out-Null
    $reader = $command1.ExecuteReader()
    $archiveData = New-Object System.Data.DataTable
    $archiveData.Load($reader)

    # compare input and archive data
    $timestamp = Get-Date -Format "yyyyMMdd_HHmm"
    $finalTable = Get-ConsolidatedBulkUploadData -DataTable $dataTable -ArchiveTable $archiveData
    Log-Info -Phase 'STEP' -Message "Final table ready with $($finalTable.Rows.Count) rows to upload" -Records $finalTable.Rows.Count

    # store commercial project data upload for traceability
    if ($finalTable.Rows.Count -gt 0) {
        Set-BlobCsv -Container 'integrationdata' `
                -BlobName  "logs/TimesheetUpload_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv" `
                -Data      $finalTable `
                -Delimiter ';'
    }
    Log-Info -Phase 'STEP' -Message "Final table stored in blob for traceability" -Records $finalTable.Rows.Count
    Log-Info -Phase 'END' `
         -Message "Timesheet Loader completed with $($finalTable.Rows.Count) commercial rows"  `
         -Status 'success' -DurationMs (Get-Elapsed) -Records $($finalTable.Rows.Count)
   
return
   # drop and bulk-import non-billable projects
    $minNBDate = $NBdataTable.Compute("MIN(p_date)", "")
    $dropNB = "delete from ProjTimeData_INT_PROJ_TS where p_date >= @minNBDate"
    $command2 = New-Object System.Data.SqlClient.SqlCommand($dropNB, $connection)
    $command2.Parameters.AddWithValue("@minNBDate", $minNBDate) | Out-Null
    $rowsAffected = $command2.ExecuteNonQuery()
    Log-info -Phase 'STEP' -Message "Deleted $rowsAffected rows non-billable rows from stage table" -Records $rowsAffected

    $transaction = $connection.BeginTransaction()
    $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($connection, [System.Data.SqlClient.SqlBulkCopyOptions]::Default, $transaction)
    $bulkCopy.DestinationTableName = "dbo.ProjTimeData_INT_PROJ_TS"
    $bulkCopy.BatchSize = 5000
    $bulkCopy.BulkCopyTimeout = 600

    Log-Info -Phase 'STEP' -Message "Writing $($NBdataTable.Rows.Count) NB rows to SQL Server..." -Records $NBdataTable.Rows.Count
    $bulkCopy.WriteToServer($NBdataTable)
    $transaction.Commit()
    Log-Info -Phase 'STEP' -Message "✅ Bulk insert 1 completed successfully." -Records 0
return
    exit(0)
    $checkStageEmpty = "select count(*) from ProjTimeDataTS"
    $commandCheck = New-Object System.Data.SqlClient.SqlCommand($checkStageEmpty, $connection)
    $stageCount = $commandCheck.ExecuteScalar()
    Log-Info -Phase 'STEP' -Message "Stage table contains $stageCount rows." -Records $stageCount
    if ($stageCount -gt 0) {
        Log-Warning -Phase 'STEP' -Message "Stage table ProjTimeDataTS is not empty. Aborting to prevent data duplication." -Records 0
        throw "Stage table ProjTimeDataTS is not empty."
    }

    if ($finalTable.Rows.Count -eq 0) {
        Log-Info -Phase 'STEP' -Message "No new or changed rows to upload after comparison with archive. Ending process." -Records 0
    } else {

    # bulk import project lines into ProjTimeDataTS table
    $transaction = $connection.BeginTransaction()
    # Create a bulk copy within the transaction
    $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($connection, [System.Data.SqlClient.SqlBulkCopyOptions]::Default, $transaction)
    $bulkCopy.DestinationTableName = "dbo.ProjTimeDataTS"
    $bulkCopy.BatchSize = 5000
    $bulkCopy.BulkCopyTimeout = 600

    Log-Info -Phase 'STEP' -Message "Writing $($finalTable.Rows.Count) rows to SQL Server..." -Records $finalTable.Rows.Count
    $bulkCopy.WriteToServer($finalTable)

    # Commit
    $transaction.Commit()
    
    Write-StagingLog -ProcessName'ProjTimeDataTS_Delta'  -Status 'SUCCESS'  -Count $finalTable.Rows.Count `
                     -Start $flowStartTime -End ([datetime]::UtcNow) -ConnectionString $ConnectionString 

    Log-Info -Phase 'END' -Level 'INFO' -Message "✅ Bulk insert 2 completed successfully." -Records $finalTable.Rows.Count
 
    }

    } catch {
        Log-Error -Message "Bulk insert failed: $_" -Level 'ERROR'
        Write-StagingLog -ProcessName 'ProjTimeDataTS_Delta' -Status 'ERROR' -Count $finalTable.Rows.Count
        if ($transaction) { $transaction.Rollback() }
        throw
    } finally {
        if ($connection.State -eq 'Open') { $connection.Close() }
    }


} catch {
    Log-Error -Message "An error occurred: $_" -Level 'ERROR'

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