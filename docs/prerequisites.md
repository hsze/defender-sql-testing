# Prerequisites

Use this checklist before deploying the Defender for Cloud SQL testing lab.

## Azure subscription requirements

Your Azure subscription should meet all of the following:

- You have **Contributor** or **Owner** access on the target subscription.
- **Microsoft Defender for Cloud** is enabled.
- The **Defender for Databases** plan is enabled for the subscription that will host the test resources.

### Recommended validation checks

- Confirm you can create resource groups, virtual machines, and SQL resources.
- Confirm Defender plans can be viewed and updated in **Microsoft Defender for Cloud**.
- Confirm your test subscription is approved for temporary VM and SQL spend.

## Required Azure permissions for simulations

Simulation and deployment tasks need elevated permissions beyond simple read access.

### Minimum role guidance

| Task | Recommended role |
|---|---|
| Deploy test resources | **Contributor** or **Owner** |
| Run security simulations | **Security Admin** or **Contributor** |
| Assign or update policy-based resources | **Resource Policy Contributor** |

### Required actions

The identity running the scripts should be able to perform these operations:

- `Microsoft.Compute/virtualMachines/write`
- `Microsoft.Resources/deployments/*`
- Policy-related deployment actions through **Resource Policy Contributor** when policy-based deployments are used

> If you are using a custom role, include the required actions above and any additional networking, storage, and SQL resource permissions needed by your environment.

## Local tooling requirements

Use one of the following local administration options:

- **PowerShell 7+** recommended
- **Az PowerShell module 7.0+** or **Azure CLI 2.50+**

### PowerShell module installation

```powershell
Install-Module Az -Scope CurrentUser
```

### Optional version checks

```powershell
$PSVersionTable.PSVersion
Get-InstalledModule Az
az version
```

## SQL Server configuration requirements

For SQL attack simulation and Defender alert generation:

- **SQL Authentication mode must be enabled**.
- Do **not** rely on Windows-only authentication.
- Use **test credentials only**.
- Never reuse production SQL logins, passwords, or connection strings.

### Credential guidance

- Create a dedicated SQL login for testing.
- Use a strong password stored securely during the test window.
- Rotate or delete the test login after cleanup.

## Network requirements

The lab environment must allow required service communication.

- Ensure **outbound connectivity** is available for Defender and Azure telemetry.
- If SQL firewall rules are used, **allow Azure services** through the firewall where appropriate.
- Verify DNS resolution and outbound HTTPS access are not blocked by local or perimeter controls.

## Cost considerations

This repository is intended for temporary validation, not long-running production use.

### VM cost considerations

Typical SQL testing in Azure often uses small-to-medium VM sizes such as:

| VM size | Typical use | Cost note |
|---|---|---|
| `Standard_D4s_v3` | Default for this lab (4 vCPU, 16 GB) | Recommended; supports nested virt for Arc track |
| `Standard_B2ms` | Minimal lab testing | Lower cost but slower SQL performance |
| `Standard_D8s_v3` | Arc track Hyper-V host | Required for nested virtualization |

Actual pricing varies by region, licensing, OS image, and reservation model. Check the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) before deployment.

### Defender for Cloud pricing

- **Microsoft Defender for Cloud** charges separately from core VM and SQL resource costs.
- The **Defender for Databases** plan adds metered security cost for protected resources.
- Log ingestion, retention, and Sentinel usage can create additional charges.

### Tips to minimize costs

- Prefer **B-series VMs** for short testing cycles when performance requirements are modest.
- Deploy only the scenario you need: IaaS SQL VM or PaaS SQL Database.
- Run simulations during a short testing window, then clean up immediately.
- Use the repository cleanup workflow after validation.
- Avoid leaving Log Analytics, Sentinel, and unused public IP resources running longer than needed.

## Pre-deployment checklist

Before moving to the quick start guide, confirm:

- [ ] You have **Contributor** or **Owner** access.
- [ ] **Defender for Cloud** is enabled.
- [ ] **Defender for Databases** is enabled.
- [ ] You have **Security Admin** or **Contributor** rights for simulations.
- [ ] You can install and use **Az PowerShell** or **Azure CLI**.
- [ ] SQL Authentication mode will be enabled.
- [ ] Only test credentials will be used.
- [ ] Outbound telemetry connectivity is allowed.
- [ ] You understand the temporary lab cost impact.

Next: continue with [quickstart.md](quickstart.md).
