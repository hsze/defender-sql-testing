# Quick Start

This guide walks through the end-to-end workflow: deploy a SQL VM with Defender for SQL, run attack simulations, verify alerts, and clean up.

> This quickstart covers the **Simulator Track** (SQL on Azure VM / Arc-enabled SQL). For Azure SQL Database (PaaS), see the [PaaS track in the main README](../README.md#azure-sql-database-paas-track).

## Step 1: Verify prerequisites

Before deploying, confirm access, tooling, and Defender plan status.

### Check Azure subscription context

```powershell
Connect-AzAccount
Get-AzContext
Get-AzSubscription | Select-Object Name, Id, State
```

### Verify Defender for Cloud status

1. Open the **Azure portal**.
2. Go to **Microsoft Defender for Cloud** > **Environment settings**.
3. Select your subscription.
4. Confirm **Defender for Databases** is enabled and **SQL servers on machines** is toggled **On**.

PowerShell check:

```powershell
Get-AzSecurityPricing -Name SqlServerVirtualMachines | Select-Object Name, PricingTier
```

### Install required modules

```powershell
Install-Module Az -Scope CurrentUser -Force
# Verify
Get-InstalledModule Az | Select-Object Name, Version
```

Required modules: `Az.Accounts`, `Az.Resources`, `Az.Compute`, `Az.Network`, `Az.Security`, `Az.SqlVirtualMachine`.

For full requirements, see [prerequisites.md](prerequisites.md).

## Step 2: Clone and configure

```powershell
git clone https://github.com/hsze/defender-sql-testing.git
cd defender-sql-testing
```

### Choose your passwords

The deployment script will prompt for two passwords:

- **VM admin password** - for RDP access to the Azure VM
- **SQL auth password** - for the SQL login used by simulations (must be 12+ chars, mixed case/numbers/symbols)

> **Lab only**: These credentials are for an isolated test environment. Never reuse production passwords. See [SECURITY.md](../SECURITY.md).

## Step 3: Deploy infrastructure

```powershell
$adminPwd = Read-Host 'VM admin password' -AsSecureString
$sqlPwd   = Read-Host 'SQL login password (>=12 chars, mixed)' -AsSecureString

.\infrastructure\powershell\Deploy-SqlIaas.ps1 `
    -ResourceGroupName 'rg-defender-sql-test' `
    -Location          'westus2' `
    -VmName            'sqltestvm' `
    -AdminUsername      'azureadmin' `
    -AdminPassword      $adminPwd `
    -SqlAuthUsername    'sqltester' `
    -SqlAuthPassword    $sqlPwd `
    -Verbose
```

This single command:

1. Creates the resource group, VNet, NSG (RDP + 1433), and a SQL Server 2022 VM.
2. Registers the SQL IaaS extension and enables the Defender for SQL pricing plan.
3. Switches SQL Server to Mixed Mode authentication and opens TCP 1433.
4. Runs `Initialize-SqlLogins.ps1` on the VM to bootstrap SQL logins via single-user mode.

> Wait ~5 minutes after deployment for the Defender for SQL extension to fully provision.

### Verify deployment

```powershell
# Check VM and extensions
Get-AzVM -ResourceGroupName 'rg-defender-sql-test' -Name 'sqltestvm' -Status | Select-Object Name, PowerState
Get-AzVMExtension -ResourceGroupName 'rg-defender-sql-test' -VMName 'sqltestvm' | Select-Object Name, ProvisioningState

# Check Defender pricing
Get-AzSecurityPricing -Name SqlServerVirtualMachines | Select-Object Name, PricingTier
```

Expected extensions: `SqlIaasExtension`, `MicrosoftDefenderforSQL` (or `AdvancedThreatProtection.Windows`), and `AzureMonitorWindowsAgent`.

## Step 4: Run simulations

Run all 7 attack scenarios using the Microsoft simulator binary:

```powershell
.\simulations\Run-AllSimulations.ps1 `
    -ResourceGroupName 'rg-defender-sql-test' `
    -VMName            'sqltestvm' `
    -SqlUser           'sqltester' `
    -SqlPassword       'YourSqlPassword123!'
```

### Run a subset

```powershell
.\simulations\Run-AllSimulations.ps1 `
    -ResourceGroupName 'rg-defender-sql-test' `
    -VMName            'sqltestvm' `
    -SqlUser           'sqltester' `
    -SqlPassword       'YourSqlPassword123!' `
    -Attacks BruteForce,SqlInjection
```

### Available attack scenarios

| Scenario | Alert Type | Requires SQL login |
|---|---|---|
| `BruteForce` | `SQL.VM_BruteForce` | No |
| `SqlInjection` | `SQL.VM_PotentialSqlInjection` | Yes |
| `LoginSuspiciousApp` | `SQL.VM_HarmfulApplication` | Yes |
| `PrincipalAnomaly` | `SQL.VM_PrincipalAnomaly` | Yes |
| `ShellExternalSourceAnomaly` | `SQL.VM_ShellExternalSourceAnomaly` | Yes |
| `ShellObfuscation` | `SQL.VM_ShellObfuscation` | Yes |
| `DataExfiltration` | `SQL.VM_DataExfiltrationAnomaly` | Yes |

### Expected output

Each attack reports `OK`, `AUTH_FAIL`, or `FAIL`. A summary table is printed at the end. If you see `AUTH_FAIL`, the SQL login does not exist on the instance -- re-run `Initialize-SqlLogins.ps1`.

## Step 5: Verify alerts (allow 5-15 min)

### Microsoft Sentinel

Open **Microsoft Sentinel** > connected workspace > **Logs**. Run:

```kql
SecurityAlert
| where TimeGenerated > ago(30m)
| where CompromisedEntity has "sqltestvm"
| project TimeGenerated, AlertName, AlertType, AlertSeverity, CompromisedEntity
| order by TimeGenerated desc
```

Or copy a query from `kql/sentinel/` for more detailed analysis.

### Microsoft Defender XDR

Open **Microsoft Defender XDR** > **Advanced Hunting**. Use queries from `kql/xdr/`.

### Defender for Cloud portal

1. Open **Microsoft Defender for Cloud** > **Security alerts**.
2. Filter by resource name or time range.
3. Review alert details, MITRE tactics, and remediation guidance.

## Step 6: Interpret results

| Alert severity | Meaning |
|---|---|
| High | Strong malicious indication -- brute force success, SQL injection |
| Medium | Suspicious activity -- anomalous principal, geo anomaly |
| Low | Early signal -- unusual data center access |
| Informational | Activity captured, lower urgency |

Map alerts to MITRE ATT&CK tactics using the KQL output. See [kql-reference.md](kql-reference.md) for schema details.

## Step 7: Cleanup

```powershell
.\infrastructure\powershell\Remove-Resources.ps1 -ResourceGroupName 'rg-defender-sql-test'
```

Verify removal:

```powershell
Get-AzResourceGroup -Name 'rg-defender-sql-test' -ErrorAction SilentlyContinue
# Should return nothing
```

## Arc-enabled SQL Server

For testing with Arc-connected machines (simulating on-prem), see [arc-enabled/README.md](../arc-enabled/README.md). Once the Arc machine is set up, use the same `Run-AllSimulations.ps1` -- point `-ResourceGroupName`/`-VMName` at the Arc machine resource.

## Troubleshooting

| Issue | Likely cause | Fix |
|---|---|---|
| `AUTH_FAIL` on all attacks except BruteForce | SQL login doesn't exist | Re-run `Initialize-SqlLogins.ps1` via `Invoke-AzVMRunCommand` |
| Simulator exe not found | Defender for SQL extension not installed | Wait 5 min; check extensions on VM |
| "connection error 25" | Named instance mismatch | Omit `-InstanceName` for default instance |
| Shell scenarios say "disabled on server" | `xp_cmdshell` off (expected) | Alerts still generated; enable `xp_cmdshell` for full telemetry |
| No alerts after 30 min | Defender plan not Standard, or extension not healthy | Check pricing tier and extension status |
| Initialize-SqlLogins fails | Service in bad state | Restart the VM and re-run |

See also: main [README troubleshooting](../README.md#troubleshooting).
