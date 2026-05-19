# Defender for SQL — Alert Validation Lab

A turnkey lab for generating and validating **Microsoft Defender for SQL** alerts. The primary track drives the Microsoft-supplied simulator that ships with the Defender for SQL ATP extension on **SQL on Azure VM (IaaS)** and **Arc-enabled SQL Server**. A secondary track is provided for **Azure SQL Database (PaaS)**, where the on-machine simulator does **not** apply.

## End-to-end flow

```text
+===========================================================================+
|              DEFENDER FOR SQL — ALERT VALIDATION LAB                       |
+===========================================================================+

 PHASE 1: DEPLOY WORKLOAD            PHASE 2: GENERATE ALERTS         PHASE 3: VALIDATE ALERTS         PHASE 4: CLEANUP
 (infrastructure/, arc-enabled/)     (simulations/)                   (kql/)                           (infrastructure/)

 --- SIMULATOR TRACK (Defender for SQL on Machines) ---

 +---------------------------+        +-------------------------+      +-------------------------+    +--------------------------+
 | Option A: SQL on Azure VM |\       | Run-AllSimulations.ps1  |      | Sentinel (SecurityAlert)|    | Remove-Resources.ps1     |
 | (IaaS)                    | \      | drives 7 scenarios via  |----->|  kql/sentinel/*.kql     |--->| or                       |
 | Deploy-SqlIaas.ps1        |  \---->| Microsoft.SQL.ADS.      |      | Defender XDR (AlertInfo)|    | Remove-ArcResources.ps1  |
 +---------------------------+   |    | DefenderForSQL.exe      |      |  kql/xdr/*.kql          |    +--------------------------+
                                 |    |  - BruteForce           |      +-------------------------+
 +---------------------------+   |    |  - SqlInjection         |
 | Option B: Arc-enabled SQL |---|    |  - LoginSuspiciousApp   |
 | (on-prem / nested Hyper-V)|        |  - PrincipalAnomaly     |
 | arc-enabled/*             |        |  - ShellExternalSrcAnom |
 +---------------------------+        |  - ShellObfuscation     |
                                      |  - DataExfiltration     |
                                      +-------------------------+

 --- PAAS TRACK (Defender for Azure SQL Databases) — separate alert pipeline ---

 +---------------------------+        +-------------------------+      +-------------------------+
 | Option C: Azure SQL DB    |        | Client-driven query     |      | Same Sentinel / XDR     |
 | (PaaS)                    |------->| patterns + sign-in      |----->| queries (SQL.DB_* alert |
 | Deploy-SqlPaas.ps1        |        | anomalies               |      | types instead of VM_*)  |
 +---------------------------+        | (simulator binary does  |      +-------------------------+
                                      |  NOT apply to PaaS)     |
                                      +-------------------------+
```

In ~15 minutes (simulator track) you can:

1. Deploy a SQL Server 2022 VM (or Arc-enable an existing SQL Server) with Defender for SQL enabled.
2. Bootstrap a SQL login the simulator can authenticate with.
3. Trigger all 7 attack scenarios programmatically (no portal clicks).
4. Verify the resulting alerts in Microsoft Defender for Cloud, Microsoft Sentinel, and Microsoft Defender XDR.

## What this lab is (and isn't)

- ✅ Drives the **official Microsoft simulator binary** (`Microsoft.SQL.ADS.DefenderForSQL.exe`) — the same binary the "Simulate alert" button in the Azure portal invokes — for both **SQL on Azure VM** and **Arc-enabled SQL Server**.
- ✅ Repeatable: deploy → bootstrap → run-all → query KQL → cleanup.
- ❌ Not a homegrown attack toolkit. We do not ship `Invoke-SqlInjection`-style scripts; Defender for SQL only raises alerts from its own simulator + the underlying telemetry it recognises.
- ⚠️ **The simulator binary does not exist on Azure SQL Database (PaaS).** [`Simulate alerts for Defender for SQL servers on machines`](https://learn.microsoft.com/en-us/azure/defender-for-cloud/simulate-alerts-sql-machines) explicitly targets the machines plan (IaaS + Arc). PaaS alert generation is a separate track — see [Azure SQL Database (PaaS) track](#azure-sql-database-paas-track) below.

## Repository layout

```
defender-sql-testing/
├── infrastructure/
│   ├── powershell/
│   │   ├── Deploy-SqlIaas.ps1          # SIMULATOR TRACK: SQL Server 2022 VM + Defender + login bootstrap
│   │   ├── Deploy-SqlPaas.ps1          # PAAS TRACK: Azure SQL Database (separate alert pipeline)
│   │   ├── Enable-DefenderForSql.ps1   # Enable the Defender for SQL pricing plan(s)
│   │   └── Remove-Resources.ps1        # Tear down
│   └── bicep/                          # Equivalent IaC modules
├── arc-enabled/                        # SIMULATOR TRACK: Arc-connected SQL Servers (on-prem / nested Hyper-V)
├── simulations/
│   ├── Initialize-SqlLogins.ps1        # Bootstraps SQL logins via single-user mode (machines track)
│   └── Run-AllSimulations.ps1          # Runs all 7 simulator scenarios via Invoke-AzVMRunCommand
├── kql/
│   ├── sentinel/                       # KQL for Sentinel / Log Analytics (SecurityAlert)
│   └── xdr/                            # KQL for Defender XDR Advanced Hunting (AlertInfo)
└── docs/                               # Prerequisites, quickstart, KQL reference
```

## Prerequisites

- Azure subscription with **Microsoft Defender for SQL servers on machines** plan enabled.
- A Microsoft Sentinel workspace (Log Analytics) connected to the subscription's Defender for Cloud, **or** Microsoft Defender XDR ingestion enabled.
- PowerShell 7+ on your workstation.
- Az PowerShell modules: `Az.Accounts`, `Az.Resources`, `Az.Compute`, `Az.Network`, `Az.Security`, `Az.SqlVirtualMachine`.
- An Azure account with **Contributor** + **Security Admin** (or equivalent) on the target subscription/resource group.
- A subscription with sufficient vCPU quota for `Standard_D4s_v3` in your chosen region.

```powershell
Install-Module Az -Scope CurrentUser
Connect-AzAccount
Set-AzContext -Subscription '<your-subscription-id>'
```

## Quick start (3 commands)

> Replace the placeholders. Keep the passwords; you will pass `-SqlPassword` to the simulator wrapper.

### 1. Deploy infrastructure (SQL VM + Defender + bootstrap)

```powershell
$adminPwd = Read-Host 'VM admin password' -AsSecureString
$sqlPwd   = Read-Host 'SQL login password (>=12 chars, mixed)' -AsSecureString

.\infrastructure\powershell\Deploy-SqlIaas.ps1 `
    -ResourceGroupName 'rg-defender-sql-test' `
    -Location          'westus2' `
    -VmName            'sqltestvm' `
    -AdminUsername     'azureadmin' `
    -AdminPassword     $adminPwd `
    -SqlAuthUsername   'sqltester' `
    -SqlAuthPassword   $sqlPwd `
    -Verbose
```

What this does:

- Creates the resource group, VNet, NSG (RDP + 1433), and a Windows Server 2022 VM running SQL Server 2022 Developer.
- Registers the SQL IaaS extension and enables the **Defender for SQL on machines** pricing plan.
- Switches SQL Server to Mixed Mode authentication and opens TCP 1433.
- Calls [`simulations/Initialize-SqlLogins.ps1`](simulations/Initialize-SqlLogins.ps1) on the VM to bootstrap SQL logins via single-user mode.

> Wait ~5 minutes after deployment for the Defender for SQL ATP extension and Azure Monitor Agent to fully provision before running simulations.

### 2. Run all 7 simulator scenarios

```powershell
.\simulations\Run-AllSimulations.ps1 `
    -ResourceGroupName 'rg-defender-sql-test' `
    -VMName            'sqltestvm' `
    -SqlUser           'sqltester' `
    -SqlPassword       '<YourSqlPassword>'
```

Sample output:

```
==> Running attack: BruteForce
    OK
    ATTACK=BruteForce EXIT=0
    SUCCESS: Successfully tested brute force on sqltestvm
==> Running attack: SqlInjection
    OK
    SUCCESS: Successfully simulated sql injection on sqltestvm
...
=== Summary ===
Attack                      Status TimeUtc              Detail
------                      ------ -------              ------
BruteForce                  OK     2026-05-19T05:08:32Z Successfully tested brute force on sqltestvm
SqlInjection                OK     2026-05-19T05:09:19Z Successfully simulated sql injection on sqltestvm
LoginSuspiciousApp          OK     2026-05-19T05:10:36Z Successfully simulated login from a suspicious app on sqltestvm
PrincipalAnomaly            OK     2026-05-19T05:11:31Z Successfully simulated login from anomalous principal
ShellExternalSourceAnomaly  OK     2026-05-19T05:12:48Z Successfully simulated shell external source anomaly
ShellObfuscation            OK     2026-05-19T05:13:35Z Successfully simulated shell obfuscation
DataExfiltration            OK     2026-05-19T05:14:52Z Successfully tested data exfiltration on sqltestvm
```

Run a subset with `-Attacks`:

```powershell
.\simulations\Run-AllSimulations.ps1 -RG 'rg-defender-sql-test' -VM 'sqltestvm' `
    -SqlUser 'sqltester' -SqlPassword '<YourSqlPassword>' `
    -Attacks BruteForce,SqlInjection
```

### 3. Verify alerts in Sentinel / XDR (allow 5–15 min for ingestion)

In **Microsoft Sentinel** (Log Analytics workspace → Logs), or **Defender XDR** Advanced Hunting, run the queries under [`kql/sentinel/`](kql/sentinel/) or [`kql/xdr/`](kql/xdr/). Quick smoke test:

```kql
SecurityAlert
| where TimeGenerated > ago(30m)
| where CompromisedEntity has "sqltestvm"
| project TimeGenerated, AlertName, AlertType, AlertSeverity, CompromisedEntity
| order by TimeGenerated desc
```

## Cleanup

```powershell
.\infrastructure\powershell\Remove-Resources.ps1 -ResourceGroupName 'rg-defender-sql-test'
```

## Attack catalog

`Run-AllSimulations.ps1` drives the simulator binary's seven scenarios. Each maps to a Defender for SQL alert type:

| Simulator scenario           | Defender alert type                                   | Requires SQL login | Notes |
|------------------------------|-------------------------------------------------------|--------------------|-------|
| `BruteForce`                 | `SQL.VM_BruteForce`                                   | No                 | Simulator iterates fake users — runs without `-u/-P`. |
| `SqlInjection`               | `SQL.VM_PotentialSqlInjection`                        | Yes                | Connects with `-u/-P` and runs an injection-pattern query. |
| `LoginSuspiciousApp`         | `SQL.VM_HarmfulApplication`                           | Yes                | Connects with a known-bad client `Application Name`. |
| `PrincipalAnomaly`           | `SQL.VM_PrincipalAnomaly`                             | Yes                | Login from a principal not seen before. |
| `ShellExternalSourceAnomaly` | `SQL.VM_ShellExternalSourceAnomaly`                   | Yes                | Reports "disabled on server" unless `xp_cmdshell` is enabled. |
| `ShellObfuscation`           | `SQL.VM_ShellObfuscation`                             | Yes                | Reports "disabled on server" unless `xp_cmdshell` is enabled. |
| `DataExfiltration`           | `SQL.VM_DataExfiltrationAnomaly`                      | Yes                | Large `SELECT` against system views. |

## How the wrapper works (under the hood)

- For each attack, the wrapper writes a tiny PowerShell script to `$env:TEMP` and ships it to the VM via `Invoke-AzVMRunCommand -CommandId RunPowerShellScript -ScriptPath ...`.
- The remote script locates `Microsoft.SQL.ADS.DefenderForSQL.exe` under `C:\Packages\Plugins\Microsoft.Azure.AzureDefenderForSQL.AdvancedThreatProtection.Windows\<version>\bin\`.
- It invokes the simulator via `cmd.exe /c "<exe> simulate -a <attack> [-u <user> -P <pass>] > log 2>&1"` to merge stdout+stderr (simulator banner is on stderr; `cmd` redirection avoids PowerShell `NativeCommandError` noise).
- Output is parsed for `Successfully (tested|simulated)` (success) or `Error:|Login failed` (failure).

## Troubleshooting

- **Every attack except `BruteForce` returns `AUTH_FAIL` / "Login failed for user"** — the SQL login passed to `-SqlUser` does not exist on the SQL instance. Re-run `Initialize-SqlLogins.ps1` (parameterized, idempotent):
  ```powershell
  Invoke-AzVMRunCommand -ResourceGroupName rg-defender-sql-test -VMName sqltestvm `
      -CommandId RunPowerShellScript `
      -ScriptPath .\simulations\Initialize-SqlLogins.ps1 `
      -Parameter @{ SqlUser='sqltester'; SqlPassword='<YourSqlPassword>' }
  ```
- **Simulator reports "connection error 25"** — you passed `-InstanceName MSSQLSERVER`. The simulator's `-i` arg is for **named instances only**. Omit it for the default instance (which is what the wrapper does by default).
- **`Shell*` scenarios say "disabled on server"** — `xp_cmdshell` is off by default. The simulator still reports `Successfully simulated`, and Defender will still raise an alert; if you want the full shell-execution telemetry path, enable `xp_cmdshell` with `sp_configure`.
- **No alerts after 30 min** — confirm:
  1. The Defender for SQL on machines **pricing plan** is `Standard` (`Get-AzSecurityPricing -Name SqlServerVirtualMachines`).
  2. The VM has the `AzureDefenderForSQL.AdvancedThreatProtection.Windows` extension installed and `Protected` status.
  3. The Azure Monitor Agent is installed and connected to the Sentinel workspace.
- **`Initialize-SqlLogins.ps1` fails to put SQL into single-user mode** — typically a previous run left the service in a bad state. Restart the VM and re-run.

## Arc-enabled track

For testing Defender for SQL on **Arc-connected machines** (simulating on-prem / hybrid), see [`arc-enabled/`](arc-enabled/). Once the Arc-connected SQL Server is registered and Defender for SQL is enabled, the same `Run-AllSimulations.ps1` workflow applies — point `-ResourceGroupName`/`-VMName` at the Arc machine resource. The simulator binary is delivered to Arc machines by the same Defender for SQL extension as for IaaS, so all 7 scenarios apply.

## Azure SQL Database (PaaS) track

> **Status: in progress.** The on-machine simulator does not work for PaaS. This section will be expanded with a working alert-generation script.

[Microsoft's machines-simulator doc](https://learn.microsoft.com/en-us/azure/defender-for-cloud/simulate-alerts-sql-machines) only covers IaaS + Arc. For **Azure SQL Database**, alerts come from **Microsoft Defender for Azure SQL Databases** (a separate plan) and must be triggered by exercising the detection patterns from a SQL client — there is no in-database binary to invoke.

Defender for Azure SQL Database alert families (alert types start with `SQL.DB_*`):

| Alert family                         | How to trigger from a client |
|--------------------------------------|------------------------------|
| `SQL.DB_BruteForce`                  | Many failed logins from one IP in a short window. |
| `SQL.DB_PotentialSqlInjection`       | Execute queries containing classic injection patterns (e.g. `' OR 1=1 --`, `; DROP TABLE`, `UNION SELECT NULL,...`). |
| `SQL.DB_VulnerabilityToSqlInjection` | Run application-style queries that produce SQL errors revealing unsanitised input. |
| `SQL.DB_HarmfulApplication`          | Connect with a client `Application Name` matching a known offensive tool (e.g. `sqlmap`, `Havij`). |
| `SQL.DB_PrincipalAnomaly`            | Sign in as a SQL login that has never been used before. |
| `SQL.DB_GeoAnomaly` / `_DomainAnomaly` / `_DataCenterAnomaly` | Sign in from an IP/region the workload has not been accessed from before (e.g. via a VPN). |
| `SQL.DB_SuspiciousIpAnomaly`         | Sign in from an IP flagged on Microsoft Threat Intelligence feeds. |
| `SQL.DB_DataExfiltrationAnomaly`     | Issue a `SELECT` that returns substantially more rows/bytes than the workload's baseline. |

**Prerequisites for the PaaS track:**

1. Deploy via [`infrastructure/powershell/Deploy-SqlPaas.ps1`](infrastructure/powershell/Deploy-SqlPaas.ps1).
2. Enable **Microsoft Defender for Azure SQL Databases** on the logical server (or via the subscription-level pricing plan `SqlServers`).
3. Allow your client IP through the server firewall (or use a private endpoint + jump box).

A PaaS-equivalent of `Run-AllSimulations.ps1` (driving `sqlcmd`/`Invoke-Sqlcmd` from your workstation against the public endpoint) is on the roadmap. Open an issue or ping the maintainer if you need it sooner.

See also: [Defender for Azure SQL alerts reference](https://learn.microsoft.com/en-us/azure/defender-for-cloud/alerts-sql-database-and-azure-synapse-analytics).

## References

- [Simulate alerts for Defender for SQL servers on machines](https://learn.microsoft.com/en-us/azure/defender-for-cloud/simulate-alerts-sql-machines)
- [Defender for SQL alerts reference](https://learn.microsoft.com/en-us/azure/defender-for-cloud/alerts-sql-database-and-azure-synapse-analytics)
- [Enable Defender for SQL servers on machines](https://learn.microsoft.com/en-us/azure/defender-for-cloud/defender-for-sql-introduction)
- [KQL quick reference](https://learn.microsoft.com/en-us/azure/data-explorer/kql-quick-reference)

## License

MIT — see [LICENSE](LICENSE).
