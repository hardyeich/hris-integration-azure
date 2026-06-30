Import-Module util_Integration -Force  -DisableNameChecking


function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxAttempts        = 3,
        [int]$DelaySeconds       = 10,
        [string]$OperationName   = 'Operation'
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return & $ScriptBlock
        } catch {
            $errMsg = $_.Exception.Message
            if ($attempt -ge $MaxAttempts) {
                Log-Error -Phase 'STEP' -Level 'ERROR' `
                          -Message "$OperationName failed after $attempt attempts" `
                          -Details $errMsg
                throw
            }
            Log-Warning -Phase 'STEP' `
                        -Message "$OperationName attempt $attempt failed, retrying in $DelaySeconds sec" `
                        -Details $errMsg
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

Initialize-Environment `
    -StorageAccountName 'saoraclehardy' `
    -ResourceGroupName  'rg-oracle-hardy' `
    -SubscriptionId     'Azure Solviasgroup.com / SoftwareOne'

$runId = New-RunId
Set-FlowInfo -FlowName 'ReportDataLoader' -System 'Azure'

$endpoints = Get-EndpointConfig

try {


    $sqlUrl = $endpoints.SqlServer.ConnectionString
    $sqlCred = $endpoints.SqlServer.Creds
    $plainPassword = [System.Net.NetworkCredential]::new("", $sqlCred.Password).Password
    $connectionString = $sqlUrl -replace '{p}', $plainPassword

    # ----------------------------
    # Configuration mapping
    # ----------------------------

    $ReportMappings = @(
          @{
            ReportName = "AbsenceAccrualsReport"
            Table   = "dbo.CON_ABSENCE_ACC"
            ColumnMap = @{
                "Person_User_Name"    = "USER_NAME"
            }
            Delimiter = ","
        },
        @{
            ReportName = "AbsenceDetailsReport"
            Table   = "dbo.CON_ABSENCE_DET"
            ColumnMap = @{}
            Delimiter = ","
        },  
        @{
            ReportName = "TimeDetailsReport"
            Table   = "dbo.CON_TIMECARD_DET"
            ColumnMap = @{
                "Person_User_Name"    = "USERNAME"
                "CostCenter_Override" = "COSTCENTER_OVERRIDE"
            }
            Delimiter = ";"
             # Chunking config
            ChunkByMonth   = $true
            StartMonth     = '2026-01-01'              # fixed start, grows over time
            DateColumn     = 'start_time'              # column used for per-chunk delete
            StartParam     = 'p_start_date'            # BIP parameter name
            EndParam       = 'p_end_date'              # BIP parameter name
        }   
     )
    # ----------------------------
    # Main Processing Loop
    # ----------------------------
    foreach (
        $mapping in $ReportMappings) {

        try {

            Set-FlowInfo  -FlowName $mapping.ReportName -System 'Azure'
            Log-Info -Phase 'START' -Message "Processing report: $($mapping.ReportName)" -Details "Target table: $($mapping.Table)" -Level 'INFO'
            $processStartDate = Get-Date
            $numRows          = 0
            
            # ── Chunked vs single-call branch ────────────────────────────────────
            if ($mapping.ContainsKey('ChunkByMonth') -and $mapping.ChunkByMonth) {

                $start = [datetime]::ParseExact($mapping.StartMonth, 'yyyy-MM-dd', $null)
                $now   = Get-Date -Day 1

                $chunks  = [System.Collections.Generic.List[hashtable]]::new()
                $current = $start
                while ($current -le $now) {
                    $chunks.Add(@{
                        StartDate = $current.ToString('yyyy-MM-dd')
                        EndDate   = $current.AddMonths(1).AddDays(0).ToString('yyyy-MM-dd')
                        Label     = $current.ToString('yyyy-MM')
                    })
                    $current = $current.AddMonths(1)
                }

                        Log-Info -Phase 'STEP' `
                        -Message "Chunks to process: $($chunks.Count)" `
                        -Details "From $($chunks[0].StartDate) to $($chunks[-1].EndDate)"

                foreach ($chunk in $chunks) {

                    Log-Info -Phase 'STEP' `
                            -Message "Loading chunk $($chunk.Label)" `
                            -Details "$($chunk.StartDate) to $($chunk.EndDate)"

                    $params = @{}
                    $params[$mapping.StartParam] = $chunk.StartDate
                    $params[$mapping.EndParam]   = $chunk.EndDate



                    # Per-chunk delete filter — clears just this month
                    $chunkFilter = "$($mapping.DateColumn) >= '$($chunk.StartDate)' " +
                                "AND $($mapping.DateColumn) < '$($chunk.EndDate)'"

                     $chunkRows = Invoke-WithRetry -OperationName "Chunk $($chunk.Label)" -ScriptBlock {

                        $res = Get-OicData -Flow         $mapping.ReportName `
                                    -BIP          'Y' `
                                    -BaseUrl      $endpoints.OIC.BaseUrl `
                                    -Credentials  $endpoints.OIC.Creds `
                                    -OutputMode   'Stream' `
                                    -ExtraParams  @{ parameters = $params } 

                        Invoke-BulkLoad `
                            -InputStream      $res.Stream `
                            -TableName        $mapping.Table `
                            -ConnectionString $connectionString `
                            -ColumnMap        $mapping.ColumnMap `
                            -Delimiter        $mapping.Delimiter `
                            -DeleteFilter     $chunkFilter 
                    }

                    Log-Info -Phase 'STEP' `
                            -Message "Chunk $($chunk.Label) loaded" `
                            -Records $chunkRows

                    $numRows += $chunkRows
                }
            }
            else {
                $res= Get-OicData -Flow  $mapping.ReportName `
                            -BIP         'Y' `
                            -BaseUrl     $endpoints.OIC.BaseUrl `
                            -Credentials $endpoints.OIC.Creds `
                            -OutputMode  'Stream' # get file path for bulk load  

                Log-Info -Phase 'STEP' -Message "OIC data retrieval result: $($res | ConvertTo-Json -Compress)" 

                $numRows =Invoke-BulkLoad  -InputStream $res.Stream   `
                            -TableName  $mapping.Table `
                            -ConnectionString $connectionString `
                            -ColumnMap $mapping.ColumnMap `
                            -Delimiter $mapping.Delimiter
            }

            $processName = $mapping.Table.Replace("dbo.", "")
            $processEndDate = Get-Date

            Write-StagingLog -ProcessName  $mapping.Table.Replace("dbo.", "") `
                     -Status       'SUCCESS' `
                     -Count        $numRows `
                     -Start        $processStartDate `
                     -End          $processEndDate `
                     -ConnectionString $endpoints.SqlServer.ConnectionString 

            $timeSpan = $processEndDate - $processStartDate
            $seconds = [math]::Round($timeSpan.TotalSeconds)
            Log-Info -Message "ReportLoader completed." -DurationMs ($seconds) -Status 'success' -Phase 'END' -Records $numRows
        }
        catch {
            $errorMsg = $_.Exception.Message
            Log-Error -Phase 'END' -Level 'ERROR' -Message  "Error processing report $($mapping.ReportName): $errorMsg"
            }
    }

}
catch {
    Log-Error -Phase 'END' -Level 'ERROR' -Message "Unhandled exception: $_"
}
