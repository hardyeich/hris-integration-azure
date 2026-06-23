Import-Module util_Integration -Force  -DisableNameChecking  
$DebugPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
# change if needed for debugging to $DebugPreference = 'Continue' etc.

  function Format-DateString {
    param(
        [Parameter(Mandatory = $false)]
        [string]$InputDate
    )

    if ([string]::IsNullOrWhiteSpace($InputDate)) {
        return ""
    }

    try {
        # Try to parse the date with PowerShell's built-in date parsing
        $dt = [datetime]::Parse($InputDate, [System.Globalization.CultureInfo]::InvariantCulture)

        # Return formatted as dd.MM.yyyy
        return $dt.ToString("dd.MM.yyyy")
    }
    catch {
        try {
            # Some formats (like 22.09.2025 or 31.12.2073 01:00) may need culture-specific parsing
            $dt = [datetime]::Parse($InputDate, [System.Globalization.CultureInfo]::GetCultureInfo("de-DE"))
            return $dt.ToString("dd.MM.yyyy")
        }
        catch {
            # If parsing fails completely, return blank
            return ""
        }
    }
}
   function Get-DeptClassificationAndKey {
    param(
        [Parameter(Mandatory=$true)]
        [string]$DepartmentName
    )
    
    $Case = "3"
    $Value = $DepartmentName # Default to the whole name (Case 3)

    $CaptureRegex = '\((.*?)\)' 
    if ($DepartmentName -match $CaptureRegex) {
        $CapturedText = $Matches[1].Trim()
        
        [int]$IntegerValue = 0
        $IsValidInteger = [int]::TryParse($CapturedText, [ref]$IntegerValue)
        
        if ($IsValidInteger) {
            # Case 1: Number found inside parentheses (e.g., 11000)
            $Case = "1"
            $Value = $IntegerValue.ToString()
            
        } else {
            # Case 2: Non-numeric text found inside parentheses (e.g., BCC, A1B)
            $Case = "2"
            $Value = $CapturedText
        }
    } else {
        $Case = "3"
    }

    # Output the required PSCustomObject with the matching key
    [PSCustomObject]@{
        ClassificationCase = $Case
        MatchingKey        = $Value
        DepartmentName     = $DepartmentName
    }
}
   function Get-Grundlast {
        param(
        [Parameter (Mandatory = $true)]
        [String]$connectionString
        )

#        $GrundlastDataPath = "C:\Users\hardy.eich\Documents\IntegrationProjects\Config\Grundlast.csv"
#        $GrundlastDataSet = Import-Csv -Path $GrundlastDataPath -Delimiter ";"
        $GrundlastMap = @{}

#        foreach ($Row in $GrundlastDataSet) {
#            $GrundlastMap[$Row.user_id.trim()] = @{
#                CostCenter    = $Row.CostCenter
#                Grundlast     = [int]$Row.Grundlast # Cast to Integer
#                Glaz_h        = [decimal]$Row.glaz_h
#                Glaz_aufbau   = [decimal]$Row.glaz_aufbau
#                Grundlast_h   = [decimal]$Row.Grundlast_h
#            }
#        }
    $gl = @"
     select 
        user_id
        ,CC as CostCenter
        ,FTE_VAL_PLAN_STDL as FTE_WERT
        ,WO_VERT 
        ,GRUNDLAST_PROZ as Grundlast
        ,GLAZ_AUFBAU_T as Glaz_aufbau
     from RessCapaEmpDet
     where user_id is not null
"@

    try {
    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    $connection.Open()
    $command = $connection.CreateCommand()
    $command.CommandText = $gl
    $reader = $command.ExecuteReader()
    $DataTable = New-Object System.Data.DataTable
    $DataTable.Load($reader)
    $reader.Close()

    # TODO should we not create entries if GL/AZAB are 0 both?
    # maybe a good idea to pick up the right cost center

    foreach ($Row in $DataTable) {
        if ([string]::IsNullOrEmpty($Row.user_id)) {
            $x=1
        }
               $GrundlastMap[$Row.user_id.trim()] = @{
                CostCenter    = $Row.CostCenter
                FTE           = $Row.FTE_WERT
                WO_VERT       = $Row.WO_VERT
                Grundlast     = $Row.Grundlast -as [int]
                Glaz_aufbau   = $Row.glaz_aufbau -as [decimal]
            }
    }
    return $GrundlastMap

    } catch {
        Write-LogError "SQL query failed: $_" 
        throw
    } finally {
        if ($connection.State -eq 'Open') { $connection.Close() }
    }
 }

 function Get-EmpIdForNonCH {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$UserName,

        [Parameter(Mandatory = $true)]
        [string]$PersonNumber,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Location,

        [Parameter(Mandatory = $true)]
        [hashtable]$AutoIdMap
    )

    $derivedId = $null
    if ($AutoIdMap.ContainsKey($PersonNumber)) {
        $idRow = $AutoIdMap[$PersonNumber]   
        if ([string]::IsNullOrEmpty($idRow.Auto_ERP_Id)) {
            if ([string]::IsNullOrEmpty($idRow.AD_PreWindows2000)) {
                    Write-LogWarning "$($Username)  has no filled AutoId map entry $($idRow.MatchStatus)"    
            } else { $derivedId =$idRow.AD_PreWindows2000 } 
        } else { 
            $derivedId =$idRow.Auto_ERP_Id
        }
    } else { Write-LogWarning "$($Username) has no AutoId map entry" }  
    return $derivedId
}

function Merge-Overrides {
      param(
        [Parameter (Mandatory = $true)]
        [String]$connectionString
        )

    $mergeStmt=@"
    -- ==========================================
    -- STEP 1: UPDATE EXISTING RECORDS
    -- ==========================================
    UPDATE T
    SET 
        T.PENSUM = CASE WHEN (T.PENSUM + S.PENSUM) < 0 THEN 0 ELSE (T.PENSUM + S.PENSUM) END,
        T.FTE_WERT = CASE WHEN (T.FTE_WERT + S.FTE_WERT) < 0 THEN 0 ELSE (T.FTE_WERT + S.FTE_WERT) END,
        T.GRUNDLAST_H = CASE WHEN (T.GRUNDLAST_H + S.GRUNDLAST_H) < 0 THEN 0 ELSE (T.GRUNDLAST_H + S.GRUNDLAST_H) END,
        T.SOLL_BRUTTO = CASE WHEN (T.SOLL_BRUTTO + S.SOLL_BRUTTO) < 0 THEN 0 ELSE (T.SOLL_BRUTTO + S.SOLL_BRUTTO) END,
        T.SOLL_NETTO = CASE WHEN (T.SOLL_NETTO + S.SOLL_NETTO) < 0 THEN 0 ELSE (T.SOLL_NETTO + S.SOLL_NETTO) END
    FROM RessCapaDataTS AS T
    INNER JOIN (
        -- Aggregate source data to prevent duplicate update crashes!
        SELECT 
            USER_ID, 
            DATUM,
            SUM(PENSUM) AS PENSUM,
            SUM(FTE_WERT) AS FTE_WERT,
            SUM(GRUNDLAST_H) AS GRUNDLAST_H,
            SUM(SOLL_BRUTTO) AS SOLL_BRUTTO,
            SUM(SOLL_NETTO) AS SOLL_NETTO
        FROM RessCapaDataAddDat
        GROUP BY USER_ID, DATUM
    ) AS S 
    ON T.USER_ID = S.USER_ID AND T.DATUM = S.DATUM;

    -- ==========================================
    -- STEP 2: INSERT NEW (AND FAKE/DUPLICATE) RECORDS
    -- ==========================================
    INSERT INTO RessCapaDataTS (
            DATUM, USER_ID, KST, PENSUM, FTE_WERT, TZ_VERT, GRUNDLAST, GLAZ_H, 
            FERIEN, KRANK, UNFALL, MU_SCH, MIL_ZS, BEZ_ABS, GESCH_ABS, GLAZ_BEZUG, 
            SOLL_BRUTTO, PERIODE, KW, QUARTAL, WOTAG, ANZ_WO_AT, WOTAG_REL, 
            SOLL_NETTO, GLAZ_AUFBAU, ABSENZ, GRUNDLAST_H
        )
    SELECT 
            S.DATUM, S.USER_ID, S.KST, S.PENSUM, S.FTE_WERT, S.TZ_VERT, S.GRUNDLAST, S.GLAZ_H, 
            S.FERIEN, S.KRANK, S.UNFALL, S.MU_SCH, S.MIL_ZS, S.BEZ_ABS, S.GESCH_ABS, S.GLAZ_BEZUG, 
            S.SOLL_BRUTTO, S.PERIODE, S.KW, S.QUARTAL, S.WOTAG, S.ANZ_WO_AT, S.WOTAG_REL, 
            S.SOLL_NETTO, S.GLAZ_AUFBAU, S.ABSENZ, S.GRUNDLAST_H
    FROM RessCapaDataAddDat AS S
    WHERE NOT EXISTS (
        -- Only insert if the User/Date combination isn't in the target table yet
        SELECT 1 
        FROM RessCapaDataTS AS T 
        WHERE T.USER_ID = S.USER_ID AND T.DATUM = S.DATUM
    );
"@
    try {
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $connection.Open()
        $command1 = $connection.CreateCommand()
        $command1.CommandText = $mergeStmt
        $command1.CommandTimeout = 300 
        $command1.ExecuteNonQuery()
        $command1.Dispose()

        Log-Info -Phase 'STEP' -Message "Merge of override data completed successfully."

    } catch {
        Log-Error -Phase  "STEP" -Level "INFO" -Message "SQL query failed: $_" 
        throw
    } finally {
        if ($connection.State -eq 'Open') { $connection.Close() }
    }

}


Initialize-Environment `
    -StorageAccountName 'saoraclehardy' `
    -ResourceGroupName  'rg-oracle-hardy' `
    -SubscriptionId     'Azure Solviasgroup.com / SoftwareOne'

$runId = New-RunId
Set-FlowInfo -FlowName 'CapacityDataGenerator' -System 'Azure'

$endpoints = Get-EndpointConfig

# ── 1. INITIALISE ─────────────────────────────────────────────────────────────
# ── 2. LOAD DATA ──────────────────────────────────────────────────────────────
#       2a. Reference/mapping data (blob, OIC reports)
#       2b. Transactional data (OIC XML, absences)
# ── 3. PREPARE LOOKUPS ────────────────────────────────────────────────────────
#       Build hashtables from loaded data
# ── 4. PROCESS EMPLOYEES ──────────────────────────────────────────────────────
#       Per employee → per day → DataTable → bulk load
# ── 5. FINALISE ───────────────────────────────────────────────────────────────
#       Staging log, summary

# ═════════════════════════════════════════════════════════════════════════════
# Capacity Planning Load
# ═════════════════════════════════════════════════════════════════════════════

$StartDate = Get-Date -Hour 0 -Minute 0 -Second 0
$EndDate   = $StartDate.AddMonths(12)
$DropDate  = $StartDate.AddDays(-1)

Log-Info -Phase 'START' -Message "Capacity load started" `
         -Details "Period: $($StartDate.ToString('yyyy-MM-dd')) to $($EndDate.ToString('yyyy-MM-dd'))"

try {

# ═════════════════════════════════════════════════════════════════════════════
# 2. LOAD DATA
# ═════════════════════════════════════════════════════════════════════════════

    # ── 2a. Reference / mapping data ─────────────────────────────────────────
    Log-Info -Phase 'STEP' -Message "Loading reference data"

    # Cost center mapping from blob
    $costCenterMapRaw = Get-BlobCsv -Container 'integrationdata'  -BlobName  'config/leccMapping.csv'  -Delimiter ';'
    # Schedules from blob
    $schedulesRaw = Get-BlobCsv -Container 'integrationdata'  -BlobName  'config/Schedules.csv' -Delimiter ';'
    # Holidays from blob
    $holidaysRaw = Get-BlobCsv -Container 'integrationdata'  -BlobName  'config/holidays.csv' -Delimiter ','
    # Absence type mapping from blob
    $absenceTypeMappingRaw = Get-BlobCsv -Container 'integrationdata' -BlobName  'config/AbsenceTypeMap.csv' -Delimiter ';'
    # Auto ID map from OIC report
    $autoIdResult = Get-OicData -Flow         'EmployeeDataReport' `
                                -BIP          'Y' `
                                -SearchLatest 'Y' `
                                -BaseUrl      $endpoints.OIC.BaseUrl `
                                -Credentials  $endpoints.OIC.Creds
    $autoIdRaw = $autoIdResult.Data

    Log-Info -Phase 'STEP' -Message "Reference data loaded" `
             -Details "AutoIds: $($autoIdRaw.Count) | Schedules: $($schedulesRaw.Count) | Holidays: $($holidaysRaw.Count)"

 # ── 2b. Transactional data — XML from OIC ─────────────────────────────────
    Log-Info -Phase 'STEP' -Message "Loading employee XML from OIC"

    $xmlResult = Get-OicData -Flow         'SOLCAPACITY' `
                             -BIP          'N' `
                             -SearchLatest 'Y' `
                             -BaseUrl      $endpoints.OIC.BaseUrl `
                             -Credentials  $endpoints.OIC.Creds `
                             -OutputMode  'File' 



    [xml]$XmlDocument = Get-Content -Path  $xmlResult.FilePath -Raw -Encoding UTF8

    Log-Info -Phase 'STEP' -Message "XML loaded"

# ═════════════════════════════════════════════════════════════════════════════
# 3. PREPARE LOOKUPS
# ═════════════════════════════════════════════════════════════════════════════

    Log-Info -Phase 'STEP' -Message "Building lookup tables"

    # ── Holidays hashtable ────────────────────────────────────────────────────
    $Holidays = @{}
    $holidaysRaw | Where-Object { $_.Location -notlike '#*' } | ForEach-Object {
        $Holidays["$($_.Location)_$($_.Date)"] = $_.'Holiday Name'
    }

    # ── Schedule details hashtable ────────────────────────────────────────────
    $ScheduleDetails = @{}
    $schedulesRaw | Group-Object -Property Schedule | ForEach-Object {
        $inner = @{}
        $row   = $_.Group[0]
        foreach ($prop in $row.PSObject.Properties) {
            if ($prop.Name -eq 'Schedule') { continue }
            if ($prop.Name -match '^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$') {
                $inner[$prop.Name] = [double]$prop.Value
            } else {
                $inner[$prop.Name] = $prop.Value
            }
        }
        $ScheduleDetails[$_.Name] = $inner
    }

    # ── Auto ID hashtable ─────────────────────────────────────────────────────
    $AutoIdMap = @{}
    $autoIdRaw | ForEach-Object {
        $AutoIdMap[$_.Person_Number] = @{
            Auto_ERP_Id       = $_.Sol_erp_msd
            AD_PreWindows2000 = $_.Username
        }
    }

    # ── Absence type map hashtable ────────────────────────────────────────────
    $AbsenceCategoryMap = @{}
    $absenceTypeMappingRaw | ForEach-Object {
        $AbsenceCategoryMap[$_.AbsenceType] = @{
            CategoryName = $_.Category
            UNFALL       = [int]$_.UNFALL
            GESCH_ABS    = [int]$_.GESCH_ABS
            FERIEN       = [int]$_.FERIEN
            KRANK        = [int]$_.KRANK
            BEZ_ABS      = [int]$_.BEZ_ABS
            MU_SCH       = [int]$_.MU_SCH
            MIL_ZS       = [int]$_.MIL_ZS
            GLAZ_BEZUG   = [int]$_.GLAZ_BEZUG
        }
    }

    # ── Cost center map (kept as array for Where-Object lookup) ───────────────
    $DepartmentCostCenterMap = $costCenterMapRaw

    # ── SQLServer connection string ───────────────
    $sqlUrl = $endpoints.SqlServer.ConnectionString
    $sqlCred = $endpoints.SqlServer.Creds
    $plainPassword = [System.Net.NetworkCredential]::new("", $sqlCred.Password).Password
    $sqlConnectionString = $sqlUrl -replace '{p}', $plainPassword

    # ── Grundlast from SQL ────────────────────────────────────────────────────
    $GrundlastMap = Get-Grundlast -ConnectionString $sqlConnectionString

    Log-Info -Phase 'STEP' -Message "Lookups built" `
             -Details "Holidays: $($Holidays.Count) | Schedules: $($ScheduleDetails.Count) | AbsTypes: $($AbsenceCategoryMap.Count)"


# ═════════════════════════════════════════════════════════════════════════════
# 4. PARSE EMPLOYEES AND ABSENCES FROM XML
# ═════════════════════════════════════════════════════════════════════════════

    Log-Info -Phase 'STEP' -Message "Parsing employees from XML"

    $RawEmployeeData = [System.Collections.Generic.List[PSObject]]::new()
    $persons         = $XmlDocument.SelectNodes("//Person_Detail")

    foreach ($p in $persons) {

        $PersonData   = $p.SelectNodes("Person_Data")
        $Username     = $PersonData.Person_User_Name
        $PersonNumber = $PersonData.Extract_Person_Number
        $LastName     = $PersonData.Person_Last_Name
        $assignments  = $p.SelectNodes("Assingment_DG_h/Assingment_DG/Assignment_Data")

        if ($assignments.Count -eq 0) { continue }

        foreach ($a in $assignments) {

            $Department        = $a.Organization_Basic_Name
            $Location          = $a.Location_Code
            $FTE               = $a.Assignment_FTE_Value
            $NormalHours       = $a.Extract_Assignment_Normal_Hours
            $TerminationDate   = $a.Termination_Date
            $LegalEmployerName = $a.Legal_Employer_Name
            $PersonType        = $a.Extract_Assignment_System_Person_Type
            $LatestHireDate    = $a.Person_Latest_Hire_Date

            # ── Exclusions ────────────────────────────────────────────────────
            if ([string]::IsNullOrEmpty($Department))                          { continue }
            if ([string]::IsNullOrEmpty($Location))                            { continue }
            if ($TerminationDate -and [datetime]$TerminationDate -lt $StartDate) { continue }
            if ($LegalEmployerName -notin @('Solvias AG'))                     { continue }
            if ($PersonType -notin @('EMP', 'CWK'))                            { continue }

            # ── Cost center resolution ────────────────────────────────────────
            $CDept = Get-DeptClassificationAndKey($Department)
            $CostCenter = if ($CDept.ClassificationCase -eq 1) {
                $CDept.MatchingKey
            } else {
                $ccRow = $DepartmentCostCenterMap | 
                         Where-Object { $_.Type -eq 'CostCenter' -and $_.Orcl -eq $CDept.MatchingKey } |
                         Select-Object -First 1
                if ($ccRow) { $ccRow.Msd } else { 'n/a' }
            }

            if ([string]::IsNullOrEmpty($FTE))         { $FTE = '1' }
            if ([string]::IsNullOrEmpty($NormalHours)) { $NormalHours = 40 * $FTE }

            # ── EMP_ID resolution ─────────────────────────────────────────────
            $Pattern = "^([A-Z]{4,7}[0-9]{1,2}|[A-Z]{6})$"
            if ($Username -notmatch $Pattern) {
                $UserNameAuto = Get-EmpIdForNonCH -userName     $Username `
                                                  -personNumber $PersonNumber `
                                                  -Location     $Location `
                                                  -AutoIdMap    $AutoIdMap
                if ($null -eq $UserNameAuto) { continue }
            } else {
                $UserNameAuto = $Username
            }

            # ── Work schedules ────────────────────────────────────────────────
            $schedules = $a.SelectNodes("../Work_Schedule_h/Work_Schedule_DG/Work_Schedule")
            if ($schedules.Count -eq 0) { $schedules = @($null) }

            foreach ($sched in $schedules) {
                if ($sched) {
                    $WorkSchedule         = $sched.Extract_Work_Schedule_Assignment_Schedule_Name
                    $WorkScheduleAsgStart = $sched.Extract_Work_Schedule_Assignment_Start_Date
                    $WorkScheduleAsgEnd   = $sched.Extract_Work_Schedule_Assignment_End_Date

                    if ($WorkScheduleAsgEnd -and [datetime]$WorkScheduleAsgEnd -lt $StartDate) { continue }
                } else {
                    $WorkSchedule = switch ($Location) {
                        'Kaiseraugst' { 'CH Work Schedule 100%' }
                        'Hombourg'    { 
                            if ([string]::IsNullOrEmpty($NormalHours)) { $NormalHours = '35' }
                            "FR Standard $NormalHours"
                        }
                        'RTP'         { 'US Standard Fulltime Shift' }
                        'Canton'      { 'US Standard Fulltime Shift' }
                        default       { 'CH Work Schedule 100%' }
                    }
                    $WorkScheduleAsgStart = $StartDate
                    $WorkScheduleAsgEnd   = $null
                }

                $RawEmployeeData.Add([PSCustomObject]@{
                    PersonNumber      = $PersonNumber
                    UserName          = $UserNameAuto
                    DepartmentName    = $Department
                    CostCenter        = $CostCenter
                    TerminationDate   = Format-DateString($TerminationDate)
                    LatestHireDate    = $LatestHireDate
                    WorkSchedule      = $WorkSchedule
                    WorkScheduleStart = Format-DateString($WorkScheduleAsgStart)
                    WorkScheduleEnd   = Format-DateString($WorkScheduleAsgEnd)
                    FTE               = $FTE
                    LegalEmployerName = $LegalEmployerName
                    Location          = $Location
                    NormalHours       = $NormalHours
                    ValidStart        = Format-DateString($WorkScheduleAsgStart)
                    ValidEnd          = Format-DateString($WorkScheduleAsgEnd)
                    LastName          = $LastName
                })
            }
        }
    }

    # ── Deduplicate employees ─────────────────────────────────────────────────
    $UniqueProperties = @('UserName','LastName','Location','LatestHireDate',
                          'WorkSchedule','ValidStart','ValidEnd')

    $Employees = $RawEmployeeData | 
                 Group-Object -Property $UniqueProperties | 
                 ForEach-Object {
                     if ($_.Count -gt 1) {
                         Log-Warning -Message "Duplicate employee — keeping first" `
                                     -Details "$($_.Group[0].UserName) | $($_.Count) records"
                     }
                     $_.Group[0]
                 }

    Log-Info -Phase 'STEP' -Message "$($Employees.Count) Employees parsed" -Records $Employees.Count

    # ── Parse absences ────────────────────────────────────────────────────────
    Log-Info -Phase 'STEP' -Message "Building absence lookup"

    $AbsenceLookup = @{}
    $DateFormat    = 'yyyy-MM-dd'

    $XmlDocument.SelectNodes('//Absences') |
        ForEach-Object {
            $PersonAbsenceDG  = $_.ParentNode
            $PersonAbsenceDGh = $PersonAbsenceDG.ParentNode
            $PersonDG         = $PersonAbsenceDGh.ParentNode

            [PSCustomObject]@{
                PersonNumber     = $PersonDG.Person_Data.Extract_Person_Number
                Status           = $_.Absence__Approval_Status_Code
                SubmitStatus     = $_.Absence__Status_Code
                SingleDay        = $_.Absence__Single_Day
                AbsType          = $_.Absence__Type
                AbsStartDate     = $_.Absence__Start_Date_time.Substring(0,10)
                AbsEndDate       = $_.Absence__End_Date_time.Substring(0,10)
                AbsStartDuration = $_.Absence__Start_Date_Duration
                AbsEndDuration   = $_.Absence__End_Date_Duration
                UOM              = $_.Absence__Unit_of_Measure
            }
        } |
        Where-Object {
            $_.Status -in @('APPROVED','AWAITING') -and
            $_.SubmitStatus -ne 'ORA_WITHDRAWN' -and
            [datetime]$_.AbsEndDate -gt $StartDate
        } |
        ForEach-Object {
            $pNum      = $_.PersonNumber
            $isSingle  = $_.SingleDay
            $absStart  = [datetime]$_.AbsStartDate
            $absEnd    = [datetime]$_.AbsEndDate
            $startDur  = [double]$_.AbsStartDuration
            $endDur    = [double]$_.AbsEndDuration
            $absType   = $_.AbsType
            $uom       = $_.UOM

            if (-not $AbsenceLookup.ContainsKey($pNum)) { $AbsenceLookup[$pNum] = @{} }

            $current = $absStart
            while ($current -le $absEnd) {
                $dateKey = $current.ToString($DateFormat)
                $hours   = if ($isSingle -eq 'Y')           { $startDur }
                           elseif ($current -eq $absStart)  { $startDur }
                           elseif ($current -eq $absEnd)    { $endDur   }
                           elseif ($uom -eq 'H')            { 999       }
                           else                             { 1         }

                if (-not $AbsenceLookup[$pNum].ContainsKey($dateKey)) {
                    $AbsenceLookup[$pNum][$dateKey] = @()
                }
                $AbsenceLookup[$pNum][$dateKey] += [PSCustomObject]@{
                    Type     = $absType
                    Duration = $hours
                    UOM      = $uom
                }
                $current = $current.AddDays(1)
            }
        }

    Log-Info -Phase 'STEP' -Message "Absence lookup built" `
             -Details "Employees with absences: $($AbsenceLookup.Count)"


# ═════════════════════════════════════════════════════════════════════════════
# 5. PROCESS — per employee bulk load (trading speed for memory efficiency)
# ═════════════════════════════════════════════════════════════════════════════

    Log-Info -Phase 'STEP' -Message "Starting per-employee processing"

    $SqlColumns = @(
        'DATUM','USER_ID','KST','PENSUM','FTE_WERT','TZ_VERT','GRUNDLAST',
        'GLAZ_H','FERIEN','KRANK','UNFALL','MU_SCH','MIL_ZS','BEZ_ABS',
        'GESCH_ABS','GLAZ_BEZUG','SOLL_BRUTTO','PERIODE','KW','QUARTAL',
        'WOTAG','ANZ_WO_AT','WOTAG_REL','SOLL_NETTO','GLAZ_AUFBAU',
        'ABSENZ','GRUNDLAST_H'
    )

    $conn = New-Object System.Data.SqlClient.SqlConnection($sqlConnectionString)
    $conn.Open()

    # Delete existing rows once
    $delCmd = New-Object System.Data.SqlClient.SqlCommand(
        "DELETE FROM dbo.RessCapaDataTS WHERE DATUM >= @minDate", $conn)
    $delCmd.Parameters.AddWithValue("@minDate", $DropDate) | Out-Null
    $rowsDeleted = $delCmd.ExecuteNonQuery()
    Log-Info -Phase 'STEP' -Message "Existing rows deleted" -Records $rowsDeleted

    $totalInserted = 0
    $empErrors     = 0
    $ecount        = 0

    #foreach ($employee in $Employees |Where-Object {$_.Username -in ('HEIDEPH1','FRONZKA1','THOMAVE2')}) {
    foreach ($employee in $Employees) {
        $ecount++

        $DataTable = New-Object System.Data.DataTable
        #foreach ($col in $SqlColumns) { [void]$DataTable.Columns.Add($col, [System.String]) }
        foreach ($col in $SqlColumns) {
            switch ($col) {
                'DATUM' { [void]$DataTable.Columns.Add($col, [datetime])}
                default {[void]$DataTable.Columns.Add($col, [string])}
            }
        }

        # employee-level variables
        $CurrentDate = $StartDate
        $UserName = $employee.UserName
        $PersonNumber = $employee.PersonNumber

        $CostCenter = $employee.CostCenter
        $Location = $employee.Location

        $FTE = $employee.FTE
        $FTEPercent = [decimal]$employee.FTE * 100
        $PercentageInteger = [int]([Math]::Round($FTEPercent, 0))
        $Pensum = $PercentageInteger.ToString()

        # employee has multiple rows if work shedules change
        $AssignedWorkSchedule = $employee.WorkSchedule
        try {
            $TZ_VERT       = $ScheduleDetails[$AssignedWorkSchedule]["TZ_VERT"]
            $StandardHours = $ScheduleDetails[$AssignedWorkSchedule]["BRUTTO"]
            $NumberOfWeeklyWorkdays = 5
            if ($TZ_VERT) {$NumberOfWeeklyWorkdays = $TZ_VERT.Length}
        } catch {
            Log-Error -Message "Schedule Lookup Error -  $($AssignedWorkSchedule)  not setup" -Phase 'STEP' -Level 'Warning'
        }


        # get Grundlast and related values from map based on sqlTable
        $Grundlast = 0
        $GlazAufbau = 0
        $GlazH = 0
        if ($GrundlastMap.ContainsKey($UserName)) {
            $GrundlastData = $GrundlastMap[$UserName]
            if ($GrundlastData -ne $null) {

                $Grundlast = $GrundlastData.Grundlast
                $GlazAufbau = $GrundlastData.Glaz_aufbau
                $GlazH = $GrundlastData.Glaz_aufbau
                #$Grundlast_h = $GrundlastData.Grundlast * $DailyHours / 100
                $FTE_Override = $null
                if (-not [string]::IsNullOrEmpty($GrundlastData.FTE)) {
                    $FTE_Override = $GrundlastData.FTE
                    Log-Info -Phase 'STEP' -Message "FTE Override user: $($UserName)  old: $($FTE)  new: $($FTE_Override)"
                    $FTEPercent = [decimal]$FTE_Override * 100
                    $PercentageInteger = [int]([Math]::Round($FTEPercent, 0))
                    $Pensum = $PercentageInteger.ToString()
                }
            }
        }

        while ($CurrentDate -le $EndDate) {

            # ── Date components ───────────────────────────────────────────────
            $Year         = $CurrentDate.Year
            $Month        = $CurrentDate.Month
            $Quarter      = [math]::Ceiling($Month / 3)
            $CalendarWeek = [System.Globalization.CultureInfo]::InvariantCulture.Calendar.GetWeekOfYear(
                                $CurrentDate,
                                [System.Globalization.CalendarWeekRule]::FirstFourDayWeek,
                                [DayOfWeek]::Monday)
            $DayOfWeekInt  = [int]$CurrentDate.DayOfWeek
            $WeekdayNumber = if ($DayOfWeekInt -eq 0) { 7 } else { $DayOfWeekInt }
            $DayOfWeekName = $CurrentDate.ToString("ddd",
                                [System.Globalization.CultureInfo]::GetCultureInfo("en-US"))

            # ── perDay calculations ────────────────────────────────────────
            # $PENSUM, $FTE, $TZ_VERT, $Grundlast, $DailyHours etc.
            # ... existing calculation code ...
            
            try {
            $DailyHours = $ScheduleDetails[$AssignedWorkSchedule][$DayOfWeekName]
            } catch {
            Log-Warning "Schedule issue $($AssignedWorkSchedule) $($DayOfWeekName)"
            }

            # Override $FTE if there is an entry in the grundlast map - this is to handle hourly workers with a fixed number of hours instead of a percentage FTE
            # adjust daily hours accordingly 
            #  Calculate Grundlast_h based on daily hours
            if ($GrundlastData -ne $null) {
                if ($FTE_Override -ne $null) {
                    #Write-Host "FTE Override user: $($UserName) $($CurrentDate) old: $($FTE)  new: $($FTE_Override) $($DailyHours)"
                    $DailyHours = $DailyHours * ($FTE_Override)
                    $FTE = $FTE_Override
                }
                $Grundlast_h = $GrundlastData.Grundlast * $DailyHours / 100
            }

            $WorkDay = 0
            if ($DailyHours -gt 0 ) { $Workday = 1 }

            $LookupDate = $CurrentDate.ToString("yyyy-MM-dd")
            $HolidayKey = $Location + "_" + $CurrentDate.ToString("yyyy-MM-dd")
            If ($Holidays.ContainsKey($HolidayKey)) { $Workday=0 }
            # TODO also need to reset $DailyHours to 0 ?

            # Absences

            if ($AbsenceLookup.ContainsKey($PersonNumber))
            {  #$AbsenceLookup[$PersonNumber].ContainsKey($LookupDate)

                $DayInfo = $AbsenceLookup[$PersonNumber][$LookupDate]
            } 

            $absTotalHours = 0
            $HoursAbsent = 0
            $ThisAbsenceType = 0
            $UNFALL =0 ; $GESCH_ABS=0;  $FERIEN=0; $KRANK=0; $BEZ_ABS=0; $MU_SCH=0; $MIL_ZS=0; $GLAZ_BEZUG=0;
            if ($DayInfo -ne $null) {
                # there may be more than 1 absence entries for this day
                foreach ($DayDetails in $DayInfo) {

                    if ($DayDetails.Duration -eq 999) {$hours = $DailyHours}
                    # todo - if UOM is day, check how to apply half day
                    elseif ($DayDetails.UOM -ne "H" ) {$hours = $DailyHours * $DayDetails.Duration} # for days and calendar days, duration is 1 or 0.5 for half day
                    else                              {$hours = $DayDetails.Duration}

                    $absTotalHours += $hours
                    
                    if ($absTotalHours -le $DailyHours) {
                        #process the absence entry
                        # TODO $HoursAbsent should be total hours counted capped by Daily Hours
                        $HoursAbsent = $hours

                        $ThisAbsenceType = $DayDetails.Type
                        if ($AbsenceCategoryMap.ContainsKey($ThisAbsenceType)) {
                        $Lookup = $AbsenceCategoryMap[$ThisAbsenceType] # O(1) Lookup done only ONCE
        
                        # TODO if UOM = H and hours <> 999 take those instead of daily hours
                        if ($Lookup) {
                            $UNFALL       = $Lookup.UNFALL     * $HoursAbsent
                            $GESCH_ABS    = $Lookup.GESCH_ABS  * $HoursAbsent
                            $FERIEN       = $Lookup.FERIEN     * $HoursAbsent
                            $KRANK        = $Lookup.KRANK      * $HoursAbsent
                            $BEZ_ABS      = $Lookup.BEZ_ABS    * $HoursAbsent
                            $MU_SCH       = $Lookup.MU_SCH     * $HoursAbsent
                            $MIL_ZS       = $Lookup.MIL_ZS     * $HoursAbsent
                            $GLAZ_BEZUG   = $Lookup.GLAZ_BEZUG * $HoursAbsent

                            $UNFALL       = if ($UNFALL     -eq 0) { 0 } else { $UNFALL     }
                            $GESCH_ABS    = if ($GESCH_ABS  -eq 0) { 0 } else { $GESCH_ABS  }
                            $FERIEN       = if ($FERIEN     -eq 0) { 0 } else { $FERIEN     }
                            $KRANK        = if ($KRANK      -eq 0) { 0 } else { $KRANK      }
                            $BEZ_ABS      = if ($BEZ_ABS    -eq 0) { 0 } else { $BEZ_ABS    }
                            $MU_SCH       = if ($MU_SCH     -eq 0) { 0 } else { $MU_SCH     }
                            $MIL_ZS       = if ($MIL_ZS     -eq 0) { 0 } else { $MIL_ZS     }
                            $GLAZ_BEZUG   = if ($GLAZ_BEZUG -eq 0) { 0 } else { $GLAZ_BEZUG }                            
                        }
                    }
                    else { Log-Info -Message "not in lookup: $($ThisAbsenceType)" -Phase 'STEP' -Level 'Warning'}
                    }
                    else {
                        Log-Warning -Message "overlapping absence $($UserName) $($CurrentDate) $($DailyHours) $($hours) $($absTotalHours) $($DayDetails.Type) $($DayDetails.Duration)"  -Phase 'STEP' -Level 'Warning'
                    }
                }
            }

            # SOLL_BRUTTO 0 on non-working days
            if ($Workday -gt 0) { $SollBrutto = $StandardHours} else {$SollBrutto = 0}

            # ── Write directly to DataRow ─────────────────────────────────────
            $NewRow = $DataTable.NewRow()
            #$NewRow["DATUM"]       = $CurrentDate.ToString("dd/MM/yyyy",[System.Globalization.CultureInfo]::InvariantCulture)
            $NewRow["DATUM"]       = $CurrentDate.Date
            $NewRow["USER_ID"]     = $employee.UserName.Trim()
            $NewRow["KST"]         = $employee.CostCenter.Trim()
            $NewRow["PENSUM"]      = $PENSUM
            $NewRow["FTE_WERT"]    = $FTE
            $NewRow["TZ_VERT"]     = $TZ_VERT
            $NewRow["GRUNDLAST"]   = $Grundlast
            $NewRow["GLAZ_H"]      = $GlazH
            $NewRow["FERIEN"]      = $FERIEN
            $NewRow["KRANK"]       = $KRANK
            $NewRow["UNFALL"]      = $UNFALL
            $NewRow["MU_SCH"]      = $MU_SCH
            $NewRow["MIL_ZS"]      = $MIL_ZS
            $NewRow["BEZ_ABS"]     = $BEZ_ABS
            $NewRow["GESCH_ABS"]   = $GESCH_ABS
            $NewRow["GLAZ_BEZUG"]  = $GLAZ_BEZUG
            $NewRow["SOLL_BRUTTO"] = $SollBrutto
            $NewRow["PERIODE"]     = "M" + $CurrentDate.ToString("yyyyMM")
            $NewRow["KW"]          = "W{0}{1:00}" -f $Year, $CalendarWeek
            $NewRow["QUARTAL"]     = "Q{0}{1:00}" -f $Year, $Quarter
            $NewRow["WOTAG"]       = $WeekdayNumber
            $NewRow["ANZ_WO_AT"]   = $NumberOfWeeklyWorkdays
            $NewRow["WOTAG_REL"]   = $Workday
            $NewRow["SOLL_NETTO"]  = $DailyHours
            $NewRow["GLAZ_AUFBAU"] = $GlazAufbau
            $NewRow["ABSENZ"]      = $HoursAbsent
            $NewRow["GRUNDLAST_H"] = $Grundlast_h
            [void]$DataTable.Rows.Add($NewRow)

            $CurrentDate = $CurrentDate.AddDays(1)
        }

        #$DataTable | Select-Object -First 10 | Format-Table -AutoSize
        #$DataTable | Export-Csv -Path "C:\Integration\AzureMigration\scratch\EmployeeData_$($employee.UserName).csv" -NoTypeInformation -Delimiter ';'
        #$DataTable | Export-Csv -Path "C:\Integration\AzureMigration\scratch\capDataNew.csv" -NoTypeInformation -Delimiter ';' -Append

        # ── Bulk load this employee ───────────────────────────────────────────
        try {
            $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($conn)
            $bulkCopy.DestinationTableName = "dbo.RessCapaDataTS"
            $bulkCopy.BatchSize            = 1000
            $bulkCopy.BulkCopyTimeout      = 60
            foreach ($col in $SqlColumns) { [void]$bulkCopy.ColumnMappings.Add($col, $col) }
           $bulkCopy.WriteToServer($DataTable)
           $totalInserted += $DataTable.Rows.Count
        } catch {
            Log-Error -Message "Bulk load failed" `
                      -Details "$($employee.UserName) | $($_.Exception.Message)"
            $empErrors++
        } finally {
            $bulkCopy.Close()
            $DataTable.Dispose()
            $DataTable = $null
        }

        if ($ecount % 50 -eq 0) {
            Log-Info -Phase 'STEP' -Message "Progress" `
                     -Details "$ecount / $($Employees.Count) employees | $totalInserted rows"
            [System.GC]::Collect()
        }
    }

    $conn.Close()

    Merge-Overrides -connectionString $sqlConnectionString
    Log-Info -Phase 'STEP' -Message "Overrides Merged" 

# ═════════════════════════════════════════════════════════════════════════════
# 6. FINALISE
# ═════════════════════════════════════════════════════════════════════════════

<#     Write-StagingLog -ProcessName  'CapacityLoad' `
                     -Status       $(if ($empErrors -eq 0) { 'SUCCESS' } else { 'WARNING' }) `
                     -Count        $totalInserted `
                     -Start        $script:FlowStartTime `
                     -End          ([datetime]::UtcNow) `
                     -ConnectionString $endpoints.SqlServer.ConnectionString #>

    Log-Info -Phase 'END' `
             -Message    "Capacity load complete" `
             -Status     $(if ($empErrors -eq 0) { 'SUCCESS' } else { 'WARNING' }) `
             -Records    $totalInserted `
             -Errors     $empErrors `
             -DurationSec (Get-Elapsed)

} catch {
    Log-Error -Phase 'END' -Message "Unhandled exception: $_"
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
} finally {
    if ($conn -and $conn.State -eq 'Open') { $conn.Close() }
}

