# Run-AllSimulations.ps1
# Runs Defender for SQL on Machines attack scenarios against a SQL VM using the
# Microsoft simulator binary (Microsoft.SQL.ADS.DefenderForSQL.exe) that ships
# with the Defender for SQL ATP extension.
#
# Each scenario is invoked on the VM via Invoke-AzVMRunCommand. Credentials must
# be for an EXISTING SQL login (otherwise every scenario except BruteForce fails
# with "Login failed for user '<x>'").
#
# Usage:
#   ./Run-AllSimulations.ps1 -ResourceGroupName rg-defender-sql-test-wus2 `
#       -VMName sqltestvm -SqlUser sqltester -SqlPassword '<YourSqlPassword>'
#
#   # Subset:
#   ./Run-AllSimulations.ps1 -RG ... -VM ... -SqlUser ... -SqlPassword ... `
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
    [int]$DelaySeconds = 15
)

$ErrorActionPreference = 'Stop'

# Remote script template: %ATTACK%/%INST%/%USER%/%PASS% are substituted per attack.
# Uses cmd.exe to merge stdout+stderr cleanly (avoids PowerShell NativeCommandError noise).
$remoteTemplate = @'
$ErrorActionPreference = 'Continue'
$exe = Get-ChildItem 'C:\Packages\Plugins\Microsoft.Azure.AzureDefenderForSQL.AdvancedThreatProtection.Windows' -Recurse -Filter 'Microsoft.SQL.ADS.DefenderForSQL.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $exe) { Write-Output 'ERROR: simulator exe not found'; exit 2 }
$logPath = Join-Path $env:TEMP ("sim-%ATTACK%-" + [guid]::NewGuid().ToString('N') + '.log')
# Build args: BruteForce works best without -u/-P; others need them. -i only for named instances.
$args = 'simulate -a %ATTACK%'
if ('%INST%' -ne '') { $args += ' -i %INST%' }
if ('%ATTACK%' -ne 'BruteForce' -and '%USER%' -ne '') { $args += ' -u %USER% -P "%PASS%"' }
cmd.exe /c "`"$($exe.FullName)`" $args > `"$logPath`" 2>&1"
$exit = $LASTEXITCODE
$out  = Get-Content $logPath -Raw -ErrorAction SilentlyContinue
Remove-Item $logPath -Force -ErrorAction SilentlyContinue
Write-Output "ATTACK=%ATTACK% EXIT=$exit"
$successLine = ($out -split "`r?`n") | Where-Object { $_ -match 'Successfully (tested|simulated)' } | Select-Object -First 1
$errorLine   = ($out -split "`r?`n") | Where-Object { $_ -match 'Error:|Login failed' } | Select-Object -First 1
if ($successLine) { Write-Output "SUCCESS: $successLine" }
if ($errorLine)   { Write-Output "ERROR:   $errorLine" }
'@

$results = @()
foreach ($atk in $Attacks) {
    Write-Host "==> Running attack: $atk" -ForegroundColor Cyan
    $script = $remoteTemplate `
        -replace '%ATTACK%', $atk `
        -replace '%INST%',   $InstanceName `
        -replace '%USER%',   $SqlUser `
        -replace '%PASS%',   $SqlPassword
    $tmp = Join-Path $env:TEMP "sim-$([guid]::NewGuid()).ps1"
    Set-Content -Path $tmp -Value $script -Encoding UTF8
    try {
        $r = Invoke-AzVMRunCommand `
            -ResourceGroupName $ResourceGroupName `
            -VMName $VMName `
            -CommandId 'RunPowerShellScript' `
            -ScriptPath $tmp
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }

    $stdout = ($r.Value | Where-Object { $_.Code -like '*StdOut*' } | Select-Object -ExpandProperty Message) -join "`n"
    $stderr = ($r.Value | Where-Object { $_.Code -like '*StdErr*' } | Select-Object -ExpandProperty Message) -join "`n"

    $success    = $stdout -match 'Successfully (tested|simulated)'
    $loginFail  = $stdout -match 'Login failed for user'
    $status     = if ($success) { 'OK' } elseif ($loginFail) { 'AUTH_FAIL' } else { 'FAIL' }
    $color      = if ($success) { 'Green' } elseif ($loginFail) { 'Yellow' } else { 'Red' }

    Write-Host "    $status" -ForegroundColor $color
    ($stdout -split "`n" | Where-Object { $_ -match '^(SUCCESS|ERROR|ATTACK)' }) |
        ForEach-Object { Write-Host "    $_" }
    if ($stderr.Trim()) { Write-Host "    [run-cmd stderr: $($stderr.Trim().Substring(0,[Math]::Min(200,$stderr.Trim().Length)))]" -ForegroundColor DarkGray }

    $resultLine = ($stdout -split "`n" | Where-Object { $_ -match '^(SUCCESS|ERROR):' } | Select-Object -First 1)
    $results += [pscustomobject]@{
        Attack  = $atk
        Status  = $status
        TimeUtc = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
        Detail  = ($resultLine -replace '^(SUCCESS|ERROR):\s*','').Trim()
    }

    if ($atk -ne $Attacks[-1]) { Start-Sleep -Seconds $DelaySeconds }
}

Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
$results | Format-Table -AutoSize

Write-Host ''
Write-Host 'Allow 5-15 minutes for alerts to land in Defender for Cloud / Sentinel.' -ForegroundColor Gray
Write-Host 'KQL check:' -ForegroundColor Gray
Write-Host '  SecurityAlert | where TimeGenerated > ago(30m) and CompromisedEntity has "sqltestvm" | project TimeGenerated, AlertName, AlertType, AlertSeverity' -ForegroundColor Gray
