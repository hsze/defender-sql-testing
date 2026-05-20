# Run-AllIaaSSimulations.ps1
# Runs Defender for SQL on Machines attack scenarios against a SQL VM (or
# Arc-enabled SQL Server) using the Microsoft simulator binary
# (Microsoft.SQL.ADS.DefenderForSQL.exe) that ships with the Defender for SQL
# extension.
#
# IMPORTANT — what "OK" means:
#   The wrapper reports OK when the simulator binary itself exited 0 and printed
#   "Successfully tested/simulated <X>". That is a CLIENT-SIDE confirmation: the
#   simulator performed its action (opened the connection, ran the query, etc.).
#   It is NOT a confirmation from the Defender backend that an alert was raised.
#
#   - Signature-based scenarios (BruteForce, SqlInjection, LoginSuspiciousApp,
#     ShellExternalSourceAnomaly, ShellObfuscation): a successful simulation
#     will reliably produce an alert within 5-30 minutes.
#   - Anomaly-based scenarios:
#       * PrincipalAnomaly       — fires only for a login that has never been
#                                  seen on this instance before. This wrapper
#                                  automatically provisions a fresh one-shot
#                                  SQL login for this scenario.
#       * DataExfiltrationAnomaly — requires a multi-day behavioral baseline.
#                                  Will NOT fire on a fresh lab instance.
#
# Usage:
#   ./Run-AllIaaSSimulations.ps1 -ResourceGroupName rg-defender-sql-test-wus2 `
#       -VMName sqltestvm -SqlUser sqltester -SqlPassword '<YourSqlPassword>'
#
#   # Subset:
#   ./Run-AllIaaSSimulations.ps1 -RG ... -VM ... -SqlUser ... -SqlPassword ... `
#       -Attacks BruteForce,SqlInjection

[CmdletBinding()]
param(
    [Parameter(Mandatory)][Alias('RG')]   [string]$ResourceGroupName,
    [Parameter(Mandatory)][Alias('VM')]   [string]$VMName,
    [Parameter(Mandatory)]                [string]$SqlUser,
    [Parameter(Mandatory)]                [string]$SqlPassword,
    [ValidateSet('BruteForce','SqlInjection','LoginSuspiciousApp','PrincipalAnomaly','ShellExternalSourceAnomaly','ShellObfuscation','DataExfiltration')]
    [string[]]$Attacks = @('BruteForce','SqlInjection','LoginSuspiciousApp','PrincipalAnomaly','ShellExternalSourceAnomaly','ShellObfuscation','DataExfiltration'),
    [string]$InstanceName = '',  # empty = default instance; only set this for named instances
    [int]$DelaySeconds = 15,
    # Skip provisioning a fresh login for PrincipalAnomaly (will then fall back to -SqlUser,
    # which already has connection history and almost certainly will NOT produce an alert).
    [switch]$SkipFreshPrincipal
)

$ErrorActionPreference = 'Stop'

function Invoke-VMScript {
    param(
        [Parameter(Mandatory)][string]$ScriptText,
        [Parameter(Mandatory)][string]$Tag
    )
    $tmp = Join-Path $env:TEMP ("sim-$Tag-" + [guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -Path $tmp -Value $ScriptText -Encoding UTF8
    try {
        return Invoke-AzVMRunCommand `
            -ResourceGroupName $ResourceGroupName `
            -VMName $VMName `
            -CommandId 'RunPowerShellScript' `
            -ScriptPath $tmp
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Provision a brand-new SQL login on the VM using sqlcmd over Windows auth.
# Initialize-SqlLogins.ps1 has already granted NT AUTHORITY\SYSTEM the sysadmin
# role, so the RunCommand (which runs as SYSTEM) can CREATE LOGIN successfully.
function New-FreshPrincipalLogin {
    param([string]$Password)
    $name = 'simprincipal_' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $pEsc = $Password.Replace("'", "''")
    $remote = @"
`$ErrorActionPreference = 'Continue'
`$sqlcmd = 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE'
if (-not (Test-Path `$sqlcmd)) { `$sqlcmd = (Get-Command sqlcmd.exe -ErrorAction SilentlyContinue).Source }
if (-not `$sqlcmd) { Write-Output 'ERROR: sqlcmd.exe not found'; exit 2 }
`$q = @'
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = '$name')
    CREATE LOGIN [$name] WITH PASSWORD = '$pEsc', CHECK_POLICY = OFF;
ALTER LOGIN [$name] ENABLE;
SELECT name, type_desc, is_disabled FROM sys.server_principals WHERE name = '$name';
'@
& `$sqlcmd -S . -E -W -Q `$q 2>&1
"@
    $r = Invoke-VMScript -ScriptText $remote -Tag 'fresh-login'
    $stdout = ($r.Value | Where-Object { $_.Code -like '*StdOut*' } | Select-Object -ExpandProperty Message) -join "`n"
    if ($stdout -notmatch [regex]::Escape($name)) {
        Write-Warning "Could not confirm fresh login creation. sqlcmd output:`n$stdout"
    }
    return $name
}

# Per-attack remote script template. %ATTACK%/%INST%/%USER%/%PASS% are substituted at call time.
$remoteTemplate = @'
$ErrorActionPreference = 'Continue'
$exe = Get-ChildItem 'C:\Packages\Plugins\Microsoft.Azure.AzureDefenderForSQL.AdvancedThreatProtection.Windows' -Recurse -Filter 'Microsoft.SQL.ADS.DefenderForSQL.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $exe) { Write-Output 'ERROR: simulator exe not found'; exit 2 }
$logPath = Join-Path $env:TEMP ("sim-%ATTACK%-" + [guid]::NewGuid().ToString('N') + '.log')
# Build args: BruteForce works without -u/-P; others need them. -i only for named instances.
$args = 'simulate -a %ATTACK%'
if ('%INST%' -ne '') { $args += ' -i %INST%' }
if ('%ATTACK%' -ne 'BruteForce' -and '%USER%' -ne '') { $args += ' -u %USER% -P "%PASS%"' }
cmd.exe /c "`"$($exe.FullName)`" $args > `"$logPath`" 2>&1"
$exit = $LASTEXITCODE
$out  = Get-Content $logPath -Raw -ErrorAction SilentlyContinue
Remove-Item $logPath -Force -ErrorAction SilentlyContinue
Write-Output "ATTACK=%ATTACK% EXIT=$exit USER=%USER%"
$successLine = ($out -split "`r?`n") | Where-Object { $_ -match 'Successfully (tested|simulated)' } | Select-Object -First 1
$errorLine   = ($out -split "`r?`n") | Where-Object { $_ -match 'Error:|Login failed' } | Select-Object -First 1
if ($successLine) { Write-Output "SUCCESS: $successLine" }
if ($errorLine)   { Write-Output "ERROR:   $errorLine" }
'@

# If PrincipalAnomaly is in scope, provision a fresh login now so the attack
# uses a principal that has zero connection history on this instance.
$freshLogin = $null
if (($Attacks -contains 'PrincipalAnomaly') -and -not $SkipFreshPrincipal) {
    Write-Host '==> Provisioning a fresh one-shot SQL login for PrincipalAnomaly' -ForegroundColor Cyan
    $freshLogin = New-FreshPrincipalLogin -Password $SqlPassword
    Write-Host "    Fresh login: $freshLogin" -ForegroundColor Green
}

# Detection-class metadata for clearer summary output.
$detectionClass = @{
    'BruteForce'                 = 'signature'
    'SqlInjection'               = 'signature'
    'LoginSuspiciousApp'         = 'signature'
    'ShellExternalSourceAnomaly' = 'signature'
    'ShellObfuscation'           = 'signature'
    'PrincipalAnomaly'           = 'anomaly-principal'
    'DataExfiltration'           = 'anomaly-baseline'
}

$results = @()
foreach ($atk in $Attacks) {
    Write-Host "==> Running attack: $atk" -ForegroundColor Cyan

    # For PrincipalAnomaly, use the freshly-provisioned login (unless suppressed).
    $userForRun = $SqlUser
    $passForRun = $SqlPassword
    if ($atk -eq 'PrincipalAnomaly' -and $freshLogin) {
        $userForRun = $freshLogin
        Write-Host "    Using fresh login '$userForRun' for this scenario" -ForegroundColor Gray
    }

    $script = $remoteTemplate `
        -replace '%ATTACK%', $atk `
        -replace '%INST%',   $InstanceName `
        -replace '%USER%',   $userForRun `
        -replace '%PASS%',   $passForRun

    $r = Invoke-VMScript -ScriptText $script -Tag $atk
    $stdout = ($r.Value | Where-Object { $_.Code -like '*StdOut*' } | Select-Object -ExpandProperty Message) -join "`n"
    $stderr = ($r.Value | Where-Object { $_.Code -like '*StdErr*' } | Select-Object -ExpandProperty Message) -join "`n"

    $success    = $stdout -match 'Successfully (tested|simulated)'
    $loginFail  = $stdout -match 'Login failed for user'
    $status     = if ($success) { 'SIM_OK' } elseif ($loginFail) { 'AUTH_FAIL' } else { 'FAIL' }
    $color      = if ($success) { 'Green' } elseif ($loginFail) { 'Yellow' } else { 'Red' }

    Write-Host "    $status" -ForegroundColor $color
    ($stdout -split "`n" | Where-Object { $_ -match '^(SUCCESS|ERROR|ATTACK)' }) |
        ForEach-Object { Write-Host "    $_" }
    if ($stderr.Trim()) {
        $tail = $stderr.Trim()
        Write-Host "    [run-cmd stderr: $($tail.Substring(0,[Math]::Min(200,$tail.Length)))]" -ForegroundColor DarkGray
    }

    $resultLine = ($stdout -split "`n" | Where-Object { $_ -match '^(SUCCESS|ERROR):' } | Select-Object -First 1)
    $results += [pscustomobject]@{
        Attack    = $atk
        SimStatus = $status
        TimeUtc   = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
        UserUsed  = $userForRun
        Detection = $detectionClass[$atk]
        Detail    = ($resultLine -replace '^(SUCCESS|ERROR):\s*','').Trim()
    }

    if ($atk -ne $Attacks[-1]) { Start-Sleep -Seconds $DelaySeconds }
}

Write-Host ''
Write-Host '=== Simulator results (CLIENT-SIDE only) ===' -ForegroundColor Cyan
$results | Format-Table -AutoSize Attack, SimStatus, Detection, UserUsed, TimeUtc, Detail

Write-Host ''
Write-Host 'What "SIM_OK" actually means:' -ForegroundColor Yellow
Write-Host '  - The simulator binary on the VM exited 0 and reported it performed its action.' -ForegroundColor Gray
Write-Host '  - It is NOT a confirmation that Defender raised an alert.' -ForegroundColor Gray
Write-Host ''
Write-Host 'Expected alert outcomes:' -ForegroundColor Yellow
Write-Host '  Detection=signature           -> alert reliably fires within 5-30 minutes.' -ForegroundColor Gray
Write-Host '  Detection=anomaly-principal   -> alert fires when this wrapper provisions a' -ForegroundColor Gray
Write-Host '                                   fresh one-shot login (the default behavior).' -ForegroundColor Gray
Write-Host '  Detection=anomaly-baseline    -> requires multi-day workload baseline; WILL' -ForegroundColor Gray
Write-Host '                                   NOT fire on a freshly-deployed lab VM.' -ForegroundColor Gray
Write-Host ''
Write-Host 'Verify in Sentinel / Defender for Cloud (allow 5-30 min):' -ForegroundColor Yellow
Write-Host '  SecurityAlert' -ForegroundColor Gray
Write-Host "  | where TimeGenerated > ago(1h) and CompromisedEntity has `"$VMName`"" -ForegroundColor Gray
Write-Host '  | summarize Count=count(), Last=max(TimeGenerated) by AlertType, AlertName' -ForegroundColor Gray
Write-Host '  | order by Last desc' -ForegroundColor Gray
