<#
.SYNOPSIS
Bootstraps SQL Server logins on a fresh SQL Server on Azure VM via single-user mode.

.DESCRIPTION
WARNING: LAB USE ONLY. This script creates high-privilege SQL logins (sysadmin role),
enables the sa account, and disables password policy. These configurations are
intentionally permissive for alert simulation testing. Do not use in production.
See SECURITY.md for credential handling guidance.

On a default-configured SQL Server 2022 image, only the `sa` login is a real sysadmin
and it is disabled. Even NT AUTHORITY\SYSTEM is not in the sysadmin role, which means
attempts to create SQL logins from Invoke-AzVMRunCommand (which runs as SYSTEM) fail
silently. This script restarts SQL Server in single-user mode (`/mSQLCMD`), under which
the connecting principal is automatically granted sysadmin, then:

  - Grants NT AUTHORITY\SYSTEM and BUILTIN\Administrators the sysadmin role
  - Enables `sa` and sets its password to the provided value
  - Creates the requested SQL login as sysadmin (used by Run-AllSimulations.ps1)
  - Optionally creates the `heather` simulator login

The script is designed to be executed ON THE VM (e.g. via Invoke-AzVMRunCommand).

.PARAMETER SqlUser
SQL Authentication login to create or update (becomes a sysadmin). Default: sqltester.

.PARAMETER SqlPassword
Password for $SqlUser and for `sa`. Must satisfy SQL Server password policy.

.PARAMETER HeatherPassword
Optional password for a secondary `heather` sysadmin login used as a "real user"
target by simulator attacks. Pass empty to skip creating the heather login.

.EXAMPLE
# Local execution on the VM
.\Initialize-SqlLogins.ps1 -SqlUser sqltester -SqlPassword '<YourPassword>'

.EXAMPLE
# Remote execution from a workstation
Invoke-AzVMRunCommand -ResourceGroupName rg-defender-sql-test-wus2 -VMName sqltestvm `
  -CommandId RunPowerShellScript -ScriptPath .\simulations\Initialize-SqlLogins.ps1 `
  -Parameter @{ SqlUser='sqltester'; SqlPassword='<YourPassword>' }
#>
param(
    [Parameter(Mandatory)][string]$SqlUser,
    [Parameter(Mandatory)][string]$SqlPassword,
    [string]$HeatherPassword = ''
)

$ErrorActionPreference = 'Continue'
$sqlcmd = 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE'
if (-not (Test-Path $sqlcmd)) {
    $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction SilentlyContinue).Source
    if (-not $sqlcmd) { throw 'sqlcmd.exe not found on this machine.' }
}

function Wait-SqlReady {
    param([int]$TimeoutSec = 60)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        & $sqlcmd -S . -E -W -h -1 -Q "SELECT 1" *> $null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

# Escape single quotes for SQL string literals
$u  = $SqlUser.Replace("'", "''")
$p  = $SqlPassword.Replace("'", "''")
$hp = $HeatherPassword.Replace("'", "''")

Write-Output '=== Stopping MSSQLSERVER ==='
Stop-Service MSSQLSERVER -Force
Get-Service MSSQLSERVER | Format-Table Name, Status

Write-Output '=== Starting MSSQLSERVER in single-user (SQLCMD) mode ==='
& cmd /c 'net start MSSQLSERVER /mSQLCMD' 2>&1 | Out-String | Write-Output

if (-not (Wait-SqlReady -TimeoutSec 60)) {
    Write-Output 'SQL did not become ready in single-user mode; aborting.'
    return
}

Write-Output '=== Connected as (should be sysadmin in -m mode) ==='
& $sqlcmd -S . -E -W -h -1 -Q "SELECT SUSER_NAME() AS Login, IS_SRVROLEMEMBER('sysadmin') AS IAmSysadmin"

Write-Output '=== Bootstrapping logins ==='
$boot = @"
SET NOCOUNT ON;
-- Grant SYSTEM sysadmin so future RunCommand executions can manage SQL
IF IS_SRVROLEMEMBER('sysadmin', N'NT AUTHORITY\SYSTEM') <> 1
    ALTER SERVER ROLE sysadmin ADD MEMBER [NT AUTHORITY\SYSTEM];

-- Local OS admin gets sysadmin too
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'BUILTIN\Administrators')
    CREATE LOGIN [BUILTIN\Administrators] FROM WINDOWS;
IF IS_SRVROLEMEMBER('sysadmin', N'BUILTIN\Administrators') <> 1
    ALTER SERVER ROLE sysadmin ADD MEMBER [BUILTIN\Administrators];

-- Enable sa with known password
ALTER LOGIN sa ENABLE;
ALTER LOGIN sa WITH PASSWORD = '$p';

-- Primary SQL login used by the simulator wrapper
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = '$u')
    CREATE LOGIN [$u] WITH PASSWORD = '$p', CHECK_POLICY = OFF;
ALTER LOGIN [$u] WITH PASSWORD = '$p';
ALTER LOGIN [$u] ENABLE;
IF IS_SRVROLEMEMBER('sysadmin', N'$u') <> 1
    ALTER SERVER ROLE sysadmin ADD MEMBER [$u];
"@

if ($HeatherPassword) {
$boot += @"

-- Optional secondary login used by some simulator scenarios
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = 'heather')
    CREATE LOGIN heather WITH PASSWORD = '$hp', CHECK_POLICY = OFF;
ALTER LOGIN heather WITH PASSWORD = '$hp';
ALTER LOGIN heather ENABLE;
IF IS_SRVROLEMEMBER('sysadmin', N'heather') <> 1
    ALTER SERVER ROLE sysadmin ADD MEMBER heather;
"@
}

$boot += @"

SELECT sp.name, sp.type_desc, sp.is_disabled, IS_SRVROLEMEMBER('sysadmin', sp.name) AS IsSysadmin
FROM sys.server_principals sp
WHERE sp.type IN ('S','U','G')
ORDER BY IsSysadmin DESC, sp.name;
"@

& $sqlcmd -S . -E -W -Q $boot 2>&1

Write-Output '=== Stopping single-user mode ==='
Stop-Service MSSQLSERVER -Force

Write-Output '=== Starting MSSQLSERVER normally ==='
Start-Service MSSQLSERVER
Get-Service MSSQLSERVER | Format-Table Name, Status

if (Wait-SqlReady -TimeoutSec 60) {
    Write-Output '=== Final verification (normal mode) ==='
    & $sqlcmd -S . -E -W -h -1 -Q "SET NOCOUNT ON; SELECT SUSER_NAME() AS Me, IS_SRVROLEMEMBER('sysadmin') AS IAmSysadmin"
    & $sqlcmd -S . -E -W -Q "SET NOCOUNT ON; SELECT name, is_disabled FROM sys.sql_logins ORDER BY name"
} else {
    Write-Output 'SQL did not come back up cleanly.'
}
