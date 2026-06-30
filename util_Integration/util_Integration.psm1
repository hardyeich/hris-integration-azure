# util_Integration.psm1
# Oracle HCM / D365 / AD Integration utilities
# Version 1.0.0

# ── Required assemblies ───────────────────────────────────────────────────────
Add-Type -AssemblyName System.Data
Import-Module AzTable -ErrorAction Stop

# ── CsvDataReader C# class ────────────────────────────────────────────────────
Add-Type -TypeDefinition @"
using System;
using System.Data;
using System.IO;
using System.Globalization;
using System.Collections.Generic;

public class CsvDataReader : IDataReader
{
    private StreamReader reader;
    private string[] headers;
    private string[] currentRow;
    private dynamic[] columns;
    private Dictionary<string,string> columnMap;
    private Dictionary<string,int> headerIndex;
    private char delimiter;

    private int rowNumber = 0;
    private string rawLine;

    private bool continueOnError;
    private Action<string> log;
    private Action<string> deadLetter;
    private Dictionary<string,int> columnOrdinal;
    public int TotalRowsRead { get; private set; } = 0;

    public CsvDataReader(
        Stream stream,
        dynamic[] columns,
        Dictionary<string,string> columnMap,
        char delimiter = ',',
        bool continueOnError = false,
        Action<string> log = null,
        Action<string> deadLetter = null
    )
    {
        this.reader = new StreamReader(stream);
        this.columns = columns;
        this.columnMap = columnMap;
        this.delimiter = delimiter;
        this.continueOnError = continueOnError;
        this.log = log;
        this.deadLetter = deadLetter;

        var headerLine = reader.ReadLine();
        headers = ParseCsvLine(headerLine).ToArray();

        // case-insensitive header lookup
        headerIndex = new Dictionary<string,int>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < headers.Length; i++)
        {
            var key = headers[i].Trim();
            if (!headerIndex.ContainsKey(key))
                headerIndex[key] = i;
        }

        columnOrdinal = new Dictionary<string,int>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < columns.Length; i++)
            columnOrdinal[columns[i].Name] = i;
    }

    // ── Fix 1: Skip empty lines ───────────────────────────────────────────────
    public bool Read()
    {
        do {
            rawLine = reader.ReadLine();
            if (rawLine == null) return false;
        } while (string.IsNullOrWhiteSpace(rawLine));

        currentRow = ParseCsvLine(rawLine).ToArray();
        rowNumber++;
        TotalRowsRead++;
        return true;
    }

    public int FieldCount => columns.Length;

    public object GetValue(int i)
    {
        var col = columns[i];
        string dbName = col.Name;
        string type   = col.Type;

        string csvName = dbName;
        if (columnMap != null && columnMap.ContainsKey(dbName))
            csvName = columnMap[dbName];

        int idx;
        if (!headerIndex.TryGetValue(csvName.Trim(), out idx))
            return DBNull.Value;

        if (idx >= currentRow.Length)
            return DBNull.Value;

        // ── Fix 2: Trim whitespace from raw value ─────────────────────────────
        var value = currentRow[idx].Trim();

        if (string.IsNullOrWhiteSpace(value))
            return DBNull.Value;

        try
        {
            switch (type)
            {
                case "decimal":
                    return (decimal)double.Parse(value, CultureInfo.InvariantCulture);

                case "numeric":
                    return decimal.Parse(value, CultureInfo.InvariantCulture);

                case "int":
                    return int.Parse(value);

                case "bigint":
                    return long.Parse(value);

                case "date":
                case "datetime2":
                    return DateTime.Parse(value, CultureInfo.InvariantCulture);

                default:
                    return value;
            }
        }
        catch (Exception ex)
        {
            string message =
                $"Row {rowNumber}, Column '{dbName}', CSV '{csvName}', Value '{value}', Type '{type}', RawRow: {rawLine}";

            if (!continueOnError)
                throw new Exception(message, ex);

            log?.Invoke(message);
            deadLetter?.Invoke(rawLine);

            return DBNull.Value;
        }
    }

    public string GetName(int i) => columns[i].Name;

    public int GetOrdinal(string name)
    {
        int idx;
        return columnOrdinal.TryGetValue(name, out idx) ? idx : -1;
    }

    public void Close()   => reader.Close();
    public void Dispose() => reader.Dispose();

    public bool IsClosed        => false;
    public int RecordsAffected  => -1;
    public int Depth            => 0;
    public DataTable GetSchemaTable() { return null; }
    public bool NextResult()    => false;

    public string GetString(int i)
    {
        var val = GetValue(i);
        return val == DBNull.Value ? null : val.ToString();
    }

    public int GetValues(object[] values)
    {
        int count = Math.Min(values.Length, FieldCount);
        for (int i = 0; i < count; i++)
            values[i] = GetValue(i);
        return count;
    }

    public bool IsDBNull(int i) => GetValue(i) == DBNull.Value;

    public object this[int i]      => GetValue(i);
    public object this[string name] => GetValue(GetOrdinal(name));

    public Type   GetFieldType(int i)    => typeof(object);
    public string GetDataTypeName(int i) => columns[i].Type;
    public IDataReader GetData(int i)    => null;

    public bool    GetBoolean(int i)  => (bool)GetValue(i);
    public byte    GetByte(int i)     => (byte)GetValue(i);
    public long    GetBytes(int i, long f, byte[] b, int o, int l) => 0;
    public char    GetChar(int i)     => (char)GetValue(i);
    public long    GetChars(int i, long f, char[] c, int o, int l) => 0;
    public DateTime GetDateTime(int i) => (DateTime)GetValue(i);
    public decimal  GetDecimal(int i)  => (decimal)GetValue(i);
    public double   GetDouble(int i)   => (double)GetValue(i);
    public float    GetFloat(int i)    => (float)GetValue(i);
    public Guid     GetGuid(int i)     => (Guid)GetValue(i);
    public short    GetInt16(int i)    => (short)GetValue(i);
    public int      GetInt32(int i)    => (int)GetValue(i);
    public long     GetInt64(int i)    => (long)GetValue(i);

    // ── CSV parser (handles quotes) ───────────────────────────────────────────
    private List<string> ParseCsvLine(string line)
    {
        var result   = new List<string>();
        bool inQuotes = false;
        var value    = "";

        for (int i = 0; i < line.Length; i++)
        {
            char c = line[i];

            if (c == '\"')
            {
                if (inQuotes && i + 1 < line.Length && line[i + 1] == '\"')
                {
                    value += '\"';
                    i++;
                }
                else
                {
                    inQuotes = !inQuotes;
                }
            }
            else if (c == delimiter && !inQuotes)
            {
                result.Add(value);
                value = "";
            }
            else
            {
                value += c;
            }
        }

        result.Add(value);
        return result;
    }
}
"@


# ── Module-level state ────────────────────────────────────────────────────────

$script:AuthMethod           = $null
$script:StorageContext       = $null
$script:StorageAccount       = $null
$script:ResourceGroup        = $null
$script:StorageAccountKey    = $null
$script:RunId                = $null
$script:FlowName             = $null
$script:System               = $null
$script:Environment          = 'Dev'
$script:FlowStartTime        = $null
$script:LocalConfigPath      = $null
$script:MappingCache         = [System.Collections.Generic.Dictionary[string,object]]::new()
$script:SuppressTableLogging = $false

# ── Managed Identity detection ────────────────────────────────────────────────

function Test-ManagedIdentityAvailable {
    try {
        Invoke-RestMethod `
            -Method  GET `
            -Uri     "http://169.254.169.254/metadata/instance?api-version=2021-02-01" `
            -Headers @{ Metadata = "true" } `
            -TimeoutSec 1 | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

# ── Smart connect ─────────────────────────────────────────────────────────────

function Connect-AzSmart {
    if ($env:AUTOMATION_ASSET_ACCOUNTID -or (Test-ManagedIdentityAvailable)) {
        Connect-AzAccount -Identity | Out-Null
        $script:AuthMethod        = 'ManagedIdentity'
        $script:StorageAccountKey = (Get-AzAutomationVariable -Name 'StorageAccountKey' `
                                        -ErrorAction SilentlyContinue `
                                        -ResourceGroupName 'rg-oracle-hardy' -AutomationAccountName 'aa-oracle-automation').Value
        $script:Environment       = (Get-AzAutomationVariable -Name 'Environment' `
                                        -ErrorAction SilentlyContinue  `
                                        -ResourceGroupName 'rg-oracle-hardy' -AutomationAccountName 'aa-oracle-automation').Value
        if (-not $script:Environment) { $script:Environment = 'Prod' }
    }
    else {
        Import-AzContext -Path "$HOME\.azure\context.json" | Out-Null
        $script:AuthMethod  = 'SavedContext'

        # Load key and environment from local config
        $configPath = if ($PSScriptRoot -and 
                          (Test-Path "$PSScriptRoot\config\endpoints.json")) {
            "$PSScriptRoot\config\endpoints.json"
        } else {
            "C:\Integration\AzureMigration\config\endpoints.json"
        }
        $config                   = Get-Content $configPath -Raw | ConvertFrom-Json
        $script:StorageAccountKey = $config.StorageAccountKey
        $script:Environment       = $config.Environment ?? 'Dev'
    }

    Write-Host "Auth: $($script:AuthMethod) | Environment: $($script:Environment)"
}

# ── Initialisation ────────────────────────────────────────────────────────────

function Initialize-Environment {
    param(
        [string]$StorageAccountName,
        [string]$ResourceGroupName,
        [string]$SubscriptionId
    )

    Connect-AzSmart

    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

    $script:StorageAccount = $StorageAccountName
    $script:ResourceGroup  = $ResourceGroupName
    $script:StorageContext = New-AzStorageContext `
                                -StorageAccountName $StorageAccountName `
                                -StorageAccountKey  $script:StorageAccountKey `
                                -WarningAction SilentlyContinue

    Write-Host "Storage: $StorageAccountName | Environment: $($script:Environment)"
}

# ── Endpoint config ───────────────────────────────────────────────────────────

function Get-EndpointConfig {
    if ($script:AuthMethod -eq 'ManagedIdentity') {
        $env = $script:Environment
        return @{
            Environment = $env
            Oracle      = @{
                BaseUrl = Get-AutomationVariable -Name "${env}_Oracle_BaseUrl"
                Creds   = Get-AutomationPSCredential -Name "${env}_Oracle_Rest"
            }
            OIC         = @{
                BaseUrl = Get-AutomationVariable -Name "${env}_OIC_DataRetrieval_BaseUrl"
                Creds   = Get-AutomationPSCredential -Name "${env}_OIC"
            }
            SqlServer   = @{
                ConnectionString = Get-AutomationVariable -Name "${env}_D365_SqlServerConnectionString"
                Creds            = Get-AutomationPSCredential -Name "${env}_D365_SqlServer"
            }
        }
    }
    else {
        $configPath = if ($PSScriptRoot -and
                          (Test-Path "$PSScriptRoot\config\endpoints.json")) {
            "$PSScriptRoot\config\endpoints.json"
        } else {
            "C:\Integration\AzureMigration\config\endpoints.json"
        }
        $config  = Get-Content $configPath -Raw | ConvertFrom-Json
        $root    = Split-Path $configPath -Parent | Split-Path -Parent
        $env     = $script:Environment
        $envCfg  = $config.$env

        return @{
            Environment = $env
            Oracle      = @{
                BaseUrl = $envCfg.Oracle.BaseUrl
                Creds   = Import-CliXml -Path (Join-Path $root $envCfg.Oracle.CredPath)
            }
            OIC         = @{
                BaseUrl = $envCfg.OIC.BaseUrl
                Creds   = Import-CliXml -Path (Join-Path $root $envCfg.OIC.CredPath)
            }
            SqlServer   = @{
                ConnectionString = $envCfg.SqlServer.ConnectionString
                Creds            = Import-CliXml -Path (Join-Path $root $envCfg.SqlServer.CredPath)
            }
        }
    }
}

# ── Run identity ──────────────────────────────────────────────────────────────

function New-RunId {
    $script:RunId         = [System.Guid]::NewGuid().ToString()
    $script:FlowStartTime = [DateTime]::UtcNow
    return $script:RunId
}

function Get-RunId   { return $script:RunId }

function Get-Elapsed {
    return [int]([DateTime]::UtcNow - $script:FlowStartTime).TotalSeconds
}

function Set-FlowInfo {
    param(
        [string]$FlowName,
        [string]$System
    )
    $script:FlowName = $FlowName
    $script:System   = $System
}

# ── Logging ───────────────────────────────────────────────────────────────────

function Write-LogEntry {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level    = 'INFO',
        [ValidateSet('START','STEP','SUMMARY','ERROR','END')]
        [string]$Phase    = 'STEP',
        [ValidateSet('SUCCESS','WARNING','FAILED','')]
        [string]$Status   = '',
        [nullable[int]]$Records    = $null,
        [nullable[int]]$Success    = $null,
        [nullable[int]]$Errors     = $null,
        [nullable[int]]$DurationMs = $null,
        [string]$Details  = ''
    )

    $timestamp = [DateTime]::UtcNow
    $rowKey    = "$($script:RunId)_$($timestamp.ToString('HHmmss.fff'))"

    # ── Console output ────────────────────────────────────────────────────────
    $consoleLine = "$($timestamp.ToString('yyyy-MM-dd HH:mm:ss')) | $($script:Environment) | $($script:FlowName) | $Level | $Phase | $Message"
    if ($Details) { $consoleLine += " | $Details" }
    Write-Host $consoleLine

    # ── Skip table write if suppressed ────────────────────────────────────────
    if ($script:SuppressTableLogging) { return }

    # ── Build entity ──────────────────────────────────────────────────────────
    $properties = @{
        timestamp   = $timestamp.ToString('o')
        flowId      = $script:RunId
        flowName    = $script:FlowName
        environment = $script:Environment
        system      = $script:System
        level       = $Level
        phase       = $Phase
        message     = $Message
    }

    if ($Status)          { $properties.status     = $Status     }
    if ($Details)         { $properties.details    = $Details    }
    if ($null -ne $Records)    { $properties.records    = $Records    }
    if ($null -ne $Success)    { $properties.success    = $Success    }
    if ($null -ne $Errors)     { $properties.errors     = $Errors     }
    if ($null -ne $DurationMs) { $properties.durationMs = $DurationMs }

    # ── Write to table ────────────────────────────────────────────────────────
    try {
        $table = (Get-AzStorageTable -Name 'integrationLogs' `
                                     -Context $script:StorageContext `
                                     -WarningAction SilentlyContinue).CloudTable

        Add-AzTableRow -Table        $table `
                       -PartitionKey $script:FlowName `
                       -RowKey       $rowKey `
                       -Property     $properties | Out-Null
    }
    catch {
        Write-Warning "Table write failed: $_"
    }
}

# ── Log wrappers ──────────────────────────────────────────────────────────────

function Log-Info {
    param(
        [string]$Message,
        [string]$Phase       = 'STEP',
        [string]$Status      = '',
        [string]$Details     = '',
        [nullable[int]]$Records    = $null,
        [nullable[int]]$Success    = $null,
        [nullable[int]]$Errors     = $null,
        [nullable[int]]$DurationMs = $null
    )
    Write-LogEntry -Message $Message -Level 'INFO' -Phase $Phase -Status $Status `
                   -Details $Details -Records $Records -Success $Success `
                   -Errors $Errors -DurationMs $DurationMs
}

function Log-Warning {
    param(
        [string]$Message,
        [string]$Phase   = 'STEP',
        [string]$Details = ''
    )
    Write-LogEntry -Message $Message -Level 'WARN' -Phase $Phase -Details $Details
}

function Log-Error {
    param(
        [string]$Message,
        [string]$Phase   = 'ERROR',
        [string]$Details = ''
    )
    Write-LogEntry -Message $Message -Level 'ERROR' -Phase $Phase -Details $Details
}

function Get-OicData {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Flow,

        [string]$BIP            = "Y",
        [string]$SearchLatest   = "Y",
        [hashtable]$ExtraParams = @{},

        [Parameter(Mandatory=$true)]
        [System.Management.Automation.PSCredential]$Credentials,
        [string]$OutputMode = "Memory",   # Memory | File | Stream
        [string]$TargetPath = $env:TEMP,

        [Parameter(Mandatory=$true)]
        [string]$BaseUrl,

        [char]$Delimiter = ','
    )

    $ZipPath     = Join-Path $env:TEMP "OicExport_$([System.Guid]::NewGuid().ToString('N')).zip"
    $ExtractPath = Join-Path $env:TEMP "OicExtract_$([System.Guid]::NewGuid().ToString('N'))"

    try {
        # ── Build request body ────────────────────────────────────────────────
        $body = @{
            Flow          = $Flow
            BIP           = $BIP
            SearchLatest  = $SearchLatest
        }
        foreach ($key in $ExtraParams.Keys) { $body[$key] = $ExtraParams[$key] }

        # ── Call OIC — stream zip to temp file ────────────────────────────────
        Log-Info -Phase 'STEP' -Message "Requesting OIC data" -Details "Flow: $Flow"

        Invoke-WebRequest -Uri     $BaseUrl `
                          -Method  Post `
                          -Body    ($body | ConvertTo-Json) `
                          -ContentType "application/json" `
                          -Credential  $Credentials `
                          -OutFile     $ZipPath `
                          -ErrorAction Stop

        # ── Unzip ─────────────────────────────────────────────────────────────
        Expand-Archive -Path $ZipPath -DestinationPath $ExtractPath -Force

        # ── Check for error response ──────────────────────────────────────────
        if (Test-Path "$ExtractPath/error.json") {
            $errorDetail = Get-Content "$ExtractPath/error.json" -Raw | ConvertFrom-Json
            throw "OIC returned error: $($errorDetail.errorDetails)"
        }

        # ── Read manifest ─────────────────────────────────────────────────────
        $manifest = $null
        if (Test-Path "$ExtractPath/manifest.json") {
            $manifest = Get-Content "$ExtractPath/manifest.json" -Raw | ConvertFrom-Json
            Log-Info -Phase 'STEP' -Message "Manifest received" -Details ($manifest | ConvertTo-Json -Compress)
        }

        # ── Find and read CSV results file ────────────────────────────────────
        $resultsFile = Get-ChildItem -Path $ExtractPath | 
                       Where-Object { $_.Name -ne 'manifest.json' -and $_.Name -ne 'error.json' } |
                       Select-Object -First 1

        if (-not $resultsFile) {
            throw "No results file found in OIC response zip"
        }

        $csvData = Import-Csv -Path $resultsFile.FullName `
                              -Delimiter $Delimiter `
                              -Encoding UTF8

        Log-Info -Phase 'STEP' -Message "OIC data received" -Details "Flow: $Flow" -Records $csvData.Count

        # ── Find CSV file ─────────────────────────────────────────────────────
        $resultsFile = Get-ChildItem -Path $ExtractPath |
                    Where-Object { $_.Name -notin @('manifest.json','error.json') } |
                    Select-Object -First 1

        if (-not $resultsFile) {
            throw "No results file found in OIC response zip"
        }

        switch ($OutputMode) {

            # ─────────────────────────────────────────────────────────────
            "Memory" {
                $csvData = Import-Csv -Path $resultsFile.FullName `
                                    -Delimiter $Delimiter `
                                    -Encoding UTF8

                Log-Info -Phase 'STEP' -Message "OIC data loaded (memory)" -Records $csvData.Count

                return @{
                    Data     = $csvData
                    Manifest = $manifest
                    Count    = $csvData.Count
                }
            }

            # ─────────────────────────────────────────────────────────────
            "File" {
                $targetFile = Join-Path $TargetPath $resultsFile.Name
                Move-Item $resultsFile.FullName $targetFile -Force

                Log-Info -Phase 'STEP' -Message "OIC data saved to file" -Details $targetFile

                return @{
                    FilePath = $targetFile
                    Manifest = $manifest
                }
            }

            # ─────────────────────────────────────────────────────────────
            "Stream" {
                # Open file stream (DO NOT delete yet)
                $stream = [System.IO.File]::OpenRead($resultsFile.FullName)

                Log-Info -Phase 'STEP' -Message "OIC data stream ready"

                return @{
                    Stream   = $stream
                    Manifest = $manifest
                    FilePath = $resultsFile.FullName  # for cleanup later
                }
            }

            default {
                throw "Invalid OutputMode: $OutputMode"
            }
        }
    }
    catch {
        Log-Error -Message "OIC data retrieval failed" -Details $_.Exception.Message
        throw
    }
    finally {
        # ── Clean up temp files ────────────────────────────────────────
      if ($OutputMode -eq "Memory") {
        Remove-Item $ZipPath -ErrorAction SilentlyContinue
        Remove-Item $ExtractPath -Recurse -ErrorAction SilentlyContinue
    }
    }
}

# ── Bulk load ─────────────────────────────────────────────────────────────────

function Invoke-BulkLoad {
    param(
        [Parameter(ParameterSetName="File", Mandatory=$true)]
        [string]$FilePath,

        [Parameter(ParameterSetName="Stream", Mandatory=$true)]
        [System.IO.Stream]$InputStream,

        [Parameter(Mandatory=$true)]
        [string]$TableName,

        [Parameter(Mandatory=$true)]
        [string]$ConnectionString,

        [hashtable]$ColumnMap = @{},
        [char]$Delimiter      = ',',
        [int]$BatchSize       = 50000,
        [string]$DeleteFilter = $null,     # <- new — optional WHERE clause for delete
        [switch]$SkipDelete                # <- new — bypass the delete step entirely
    )

    $connection = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    $connection.Open()
    $numRows = 0

    try {
        if ($PSCmdlet.ParameterSetName -eq "File") {
            $stream     = [System.IO.File]::OpenRead($FilePath)
            $ownsStream = $true
        } else {
            $stream     = $InputStream
            $ownsStream = $false
        }

<#         $deleteCmd             = $connection.CreateCommand()
        $deleteCmd.CommandText = "DELETE FROM $TableName"
        $deleteCmd.ExecuteNonQuery() | Out-Null #>

        if (-not $SkipDelete) {
            $deleteCmd = $connection.CreateCommand()
            $deleteCmd.CommandTimeout = 300    # <- 5 minutes 
            
            if ([string]::IsNullOrWhiteSpace($DeleteFilter)) {
                $deleteCmd.CommandText = "DELETE FROM $TableName"
                Log-Info -Message "Table $TableName cleared" -Phase 'STEP'
            } else {
                $deleteCmd.CommandText = "DELETE FROM $TableName WHERE $DeleteFilter"
                Log-Info -Message "Table $TableName cleared with filter" `
                        -Details $DeleteFilter -Phase 'STEP'
            }
            $deleteCmd.ExecuteNonQuery() | Out-Null
        }

        Log-Info -Message "Table $TableName cleared" -Phase 'STEP'

        $schemaCmd             = $connection.CreateCommand()
        $schemaCmd.CommandText = @"
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = PARSENAME('$TableName',2)
AND   TABLE_NAME   = PARSENAME('$TableName',1)
ORDER BY ORDINAL_POSITION
"@
        $schemaReader = $schemaCmd.ExecuteReader()
        $columns      = @()
        while ($schemaReader.Read()) {
            $columns += [PSCustomObject]@{
                Name = $schemaReader["COLUMN_NAME"]
                Type = $schemaReader["DATA_TYPE"].ToLower()
            }
        }
        $schemaReader.Close()

        if ($columns.Count -eq 0) { throw "No columns found for table $TableName" }

        $map = New-Object "System.Collections.Generic.Dictionary[string,string]"
        foreach ($k in $ColumnMap.Keys) { $map.Add($k, $ColumnMap[$k]) }

        $csvReader = [CsvDataReader]::new($stream, $columns, $map, $Delimiter)

        $bulkCopy                      = New-Object Data.SqlClient.SqlBulkCopy($connection)
        $bulkCopy.DestinationTableName = $TableName
        $bulkCopy.BatchSize            = $BatchSize
        $bulkCopy.BulkCopyTimeout      = 0
        $bulkCopy.EnableStreaming       = $true
        $bulkCopy.NotifyAfter          = $BatchSize
        $bulkCopy.add_SqlRowsCopied({
            param($s, $e)
            Write-Host "Copied so far: $($e.RowsCopied)"
        })

        foreach ($col in $columns) {
            $bulkCopy.ColumnMappings.Add($col.Name, $col.Name) | Out-Null
        }

        $bulkCopy.WriteToServer($csvReader)

        $numRows = $csvReader.TotalRowsRead
        Log-Info -Message "Bulk load completed for $TableName" -Phase 'STEP' -Records $numRows
        $csvReader.Close()

        return $numRows
    }
    finally {
        if ($ownsStream -and $stream) { $stream.Close() }
        $connection.Close()
    }
}

# ── Blob file retrieval ───────────────────────────────────────────────────────

function Get-BlobFile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Container,

        [Parameter(Mandatory=$true)]
        [string]$BlobName,

        [string]$LocalPath = $null,   # if null returns content as string
        [string]$Encoding  = 'UTF8'
    )

    $tmp = $LocalPath ?? [System.IO.Path]::GetTempFileName()

    try {
        Get-AzStorageBlobContent -Container $Container `
                                 -Blob      $BlobName `
                                 -Destination $tmp `
                                 -Context   $script:StorageContext `
                                 -Force `
                                 -WarningAction SilentlyContinue | Out-Null

        Log-Info -Phase 'STEP' -Message "Blob retrieved" -Details "$Container/$BlobName"

        if ($LocalPath) {
            return $LocalPath
        } else {
            # Return as string if no local path specified
            return Get-Content $tmp -Raw -Encoding $Encoding
        }
    }
    catch {
        Log-Error -Message "Blob retrieval failed" -Details "$Container/$BlobName — $($_.Exception.Message)"
        throw
    }
    finally {
        if (-not $LocalPath -and (Test-Path $tmp)) { Remove-Item $tmp -Force }
    }
}

function Get-BlobCsv {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Container,

        [Parameter(Mandatory=$true)]
        [string]$BlobName,

        [char]$Delimiter = ',',
        [string]$Encoding = 'UTF8'
    )

    $tmp = [System.IO.Path]::GetTempFileName()

    try {
        Get-AzStorageBlobContent -Container   $Container `
                                 -Blob        $BlobName `
                                 -Destination $tmp `
                                 -Context     $script:StorageContext `
                                 -Force `
                                 -WarningAction SilentlyContinue | Out-Null

        $data = Import-Csv -Path $tmp -Delimiter $Delimiter -Encoding $Encoding

        Log-Info -Phase 'STEP' -Message "CSV blob retrieved" `
                 -Details "$Container/$BlobName" -Records $data.Count

        return $data
    }
    catch {
        Log-Error -Message "CSV blob retrieval failed" `
                  -Details "$Container/$BlobName — $($_.Exception.Message)"
        throw
    }
    finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force }
    }
}

# ── Blob file upload ──────────────────────────────────────────────────────────

function Set-BlobFile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Container,

        [Parameter(Mandatory=$true)]
        [string]$BlobName,

        [Parameter(Mandatory=$true, ParameterSetName='File')]
        [string]$LocalPath,

        [Parameter(Mandatory=$true, ParameterSetName='Content')]
        [string]$Content,

        [string]$Encoding = 'UTF8'
    )

    try {
        if ($PSCmdlet.ParameterSetName -eq 'Content') {
            $tmp = [System.IO.Path]::GetTempFileName()
            $Content | Out-File -FilePath $tmp -Encoding $Encoding
            $uploadPath = $tmp
        } else {
            $uploadPath = $LocalPath
            $tmp        = $null
        }

        Set-AzStorageBlobContent -File      $uploadPath `
                                 -Container $Container `
                                 -Blob      $BlobName `
                                 -Context   $script:StorageContext `
                                 -Force `
                                 -WarningAction SilentlyContinue | Out-Null

        Log-Info -Phase 'STEP' -Message "Blob uploaded" -Details "$Container/$BlobName"
    }
    catch {
        Log-Error -Message "Blob upload failed" `
                  -Details "$Container/$BlobName — $($_.Exception.Message)"
        throw
    }
    finally {
        if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Force }
    }
}

function Set-BlobCsv {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Container,

        [Parameter(Mandatory=$true)]
        [string]$BlobName,

        [Parameter(Mandatory=$true)]
        [object[]]$Data,

        [char]$Delimiter  = ',',
        [string]$Encoding = 'UTF8'
    )

    $tmp = [System.IO.Path]::GetTempFileName()

    try {
        $Data | Export-Csv -Path $tmp `
                           -Delimiter $Delimiter `
                           -Encoding  $Encoding `
                           -NoTypeInformation

        Set-AzStorageBlobContent -File      $tmp `
                                 -Container $Container `
                                 -Blob      $BlobName `
                                 -Context   $script:StorageContext `
                                 -Force `
                                 -WarningAction SilentlyContinue | Out-Null

        Log-Info -Phase 'STEP' -Message "CSV blob uploaded" `
                 -Details "$Container/$BlobName" -Records $Data.Count
    }
    catch {
        Log-Error -Message "CSV blob upload failed" `
                  -Details "$Container/$BlobName — $($_.Exception.Message)"
        throw
    }
    finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force }
    }
}

# ── SQL staging log ───────────────────────────────────────────────────────────

function Write-StagingLog {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ProcessName,

        [Parameter(Mandatory=$true)]
        [string]$Status,

        [Parameter(Mandatory=$true)]
        [int]$Count,

        [datetime]$Start = [datetime]::UtcNow,
        [datetime]$End   = [datetime]::UtcNow,

        [string]$TableName        = 'SolTimeDataInterfaceProtocol',
        [string]$UserName         = 'EICHHA1',
        [string]$ConnectionString = $null
    )

    # Use module endpoint config if no connection string passed
    $connStr = if ($ConnectionString) {
        $ConnectionString
    } else {
        $ConnectionString =(Get-EndpointConfig).SqlServer.ConnectionString
    }
    $sqlCred = (Get-EndpointConfig).SqlServer.Creds
    $plainPassword = [System.Net.NetworkCredential]::new("", $sqlCred.Password).Password
    $connStr = $connStr -replace '{p}', $plainPassword
    

    $startStr = $Start.ToString('yyyy-MM-dd HH:mm:ss')
    $endStr   = $End.ToString('yyyy-MM-dd HH:mm:ss')

    $insertStmt = @"
INSERT INTO $TableName (IF_NAME, USER_NAME, START_DATE_TIME, END_DATE_TIME, RECORD_COUNT, STATUS)
VALUES (@ProcessName, @UserName, @Start, @End, @Count, @Status)
"@

    try {
        $connection = New-Object System.Data.SqlClient.SqlConnection($connStr)
        $connection.Open()

        $command             = $connection.CreateCommand()
        $command.CommandText = $insertStmt

        # Parameterised to avoid SQL injection
        $command.Parameters.AddWithValue('@ProcessName', $ProcessName) | Out-Null
        $command.Parameters.AddWithValue('@UserName',    $UserName)    | Out-Null
        $command.Parameters.AddWithValue('@Start',       $startStr)    | Out-Null
        $command.Parameters.AddWithValue('@End',         $endStr)      | Out-Null
        $command.Parameters.AddWithValue('@Count',       $Count)       | Out-Null
        $command.Parameters.AddWithValue('@Status',      $Status)      | Out-Null

        $command.ExecuteNonQuery() | Out-Null

        Log-Info -Phase 'STEP' -Message "Staging log written" `
                 -Details "$ProcessName | $Status | $Count records"
    }
    catch {
        Log-Error -Message "Staging log failed" -Details $_.Exception.Message
    }
    finally {
        if ($connection.State -eq 'Open') { $connection.Close() }
    }
}