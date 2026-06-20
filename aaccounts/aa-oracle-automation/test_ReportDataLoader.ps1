Import-Module util_Integration -Force  -DisableNameChecking

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

            $processName = $mapping.Table.Replace("dbo.", "")
            $processEndDate = Get-Date
            #UpdateAzureLog -config $envConfig -ProjectRoot $projectRoot -ProcessName $processName -Start $processStartDate -End $processEndDate -Count $numRows[0] -Status "SUCCESS"

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
