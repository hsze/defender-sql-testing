# Arc-Enabled SQL Server - Defender for Cloud Testing

This subfolder provides the infrastructure and guidance needed to deploy an Arc-connected SQL Server environment for testing Microsoft Defender for Cloud protections.

After the Arc-connected SQL Server is deployed and the Defender extension is healthy, use the existing scripts in the parent repository for alert generation and validation:

- Alert simulations: [`../simulations/`](../simulations/)
- KQL queries: [`../kql/`](../kql/)

The alert simulations and KQL queries work the same way for Arc-connected SQL Server as they do for SQL Server running directly on Azure virtual machines.

## What this folder is for

Use `arc-enabled/` to build the test environment for Arc-enabled SQL Server. This folder focuses on deployment and onboarding:

- Provisioning the host environment
- Installing SQL Server in the test machine
- Onboarding the machine to Azure Arc
- Deploying the Defender for SQL extension
- Preparing the environment so the existing simulation and KQL content can be reused

This folder does not replace the existing test content in the parent repository. Once setup is complete, continue testing with `../simulations/` and validate results with `../kql/`.

## Deployment approaches

### 1. Nested Hyper-V (Recommended)

This approach deploys an Azure VM with Hyper-V enabled, creates a nested VM that runs SQL Server, and onboards that nested machine to Azure Arc.

Why use it:

- Most realistic representation of an on-premises or edge SQL Server
- Clear separation between Azure host and Arc-connected guest
- Best option for validating end-to-end Arc behavior

Trade-offs:

- Adds about 15 to 20 minutes to setup time
- Requires Azure VM size that supports nested virtualization
- Slightly more networking setup because the nested VM uses an internal NAT switch

### 2. Quick-Test Override

This approach uses a normal Azure VM and sets `MSFT_ARC_TEST=true` before Arc agent installation so the machine can be onboarded for testing.

Why use it:

- Faster to deploy
- Good for validating the alert pipeline and Defender extension behavior
- Useful when nested virtualization is unavailable

Trade-offs:

- Less realistic than nested Hyper-V
- Uses an unsupported testing override flag
- Should only be used in non-production lab scenarios

## Prerequisites

Arc-enabled SQL testing has a few requirements beyond the parent repository:

- Azure subscription with permissions to create VMs, networking, and Arc resources
- Microsoft Defender for Cloud enabled with the relevant Defender for SQL plan
- Service principal for Arc onboarding
- Service principal assigned the `Azure Connected Machine Onboarding` role
- PowerShell with the `Az.ConnectedMachine` module installed
- Azure CLI with the `connectedmachine` extension available, if using CLI-based checks
- Outbound HTTPS access on port 443 from the Arc-connected machine to Azure endpoints

Example PowerShell setup:

```powershell
Install-Module Az.ConnectedMachine -Scope CurrentUser
Import-Module Az.ConnectedMachine
```

## Quick start

### Quick start: Nested Hyper-V

1. Deploy the Azure host VM with a size that supports nested virtualization.
2. Install and enable the Hyper-V role on the host VM.
3. Create an internal Hyper-V switch and configure NAT on the host.
4. Create the nested VM and install Windows plus SQL Server inside it.
5. Confirm the nested VM has outbound internet access over port 443.
6. Create or reuse a service principal with the `Azure Connected Machine Onboarding` role.
7. Install the Azure Arc agent inside the nested VM and onboard it to Azure Arc.
8. Deploy the SQL Arc or Defender-related extensions required for SQL discovery and protection.
9. Verify the `MicrosoftDefenderForSQL` extension reports healthy.
10. Run the existing simulation scripts from `../simulations/` and validate alerts with `../kql/`.

### Quick start: Quick-Test Override

1. Deploy an Azure VM and install SQL Server on it.
2. Create or reuse a service principal with the `Azure Connected Machine Onboarding` role.
3. Before installing the Arc agent, set the environment variable `MSFT_ARC_TEST=true`.
4. Install the Azure Arc agent and onboard the VM to Azure Arc.
5. Confirm the Arc machine resource appears in Azure.
6. Deploy the SQL and Defender extensions to the Arc-connected machine.
7. Verify the `MicrosoftDefenderForSQL` extension reports healthy.
8. Run the existing simulation scripts from `../simulations/` and validate alerts with `../kql/`.

## Suggested validation flow

After either deployment path is complete:

1. Verify the Arc machine shows as connected.
2. Verify SQL Server is discovered for the Arc machine.
3. Verify the Defender for SQL extension is installed and healthy.
4. Run one or more simulations from `../simulations/`.
5. Query alert data using the queries in `../kql/`.

## Folder structure

```text
arc-enabled/
|-- README.md                 # Main guide for Arc-enabled SQL testing
|-- docs/
|   |-- architecture.md       # Architecture and component flow
|   |-- troubleshooting.md    # Common issues and fixes
|-- infrastructure/           # Deployment scripts and templates for Arc test environments
```

## Relationship to the parent repository

The parent repository already contains the reusable testing assets for Defender for SQL:

- Simulations: [`../simulations/`](../simulations/)
- KQL queries: [`../kql/`](../kql/)
- Repository overview: [`../README.md`](../README.md)

Use this `arc-enabled/` folder to deploy the Arc-connected environment first, then use the parent repo content to generate and validate alerts.

## Important notes

- Arc agent onboarding requires outbound HTTPS on port 443 to Azure endpoints.
- The Arc onboarding service principal needs the `Azure Connected Machine Onboarding` role.
- Nested VMs typically add about 15 to 20 minutes to total setup time.
- The quick-test approach uses the unsupported `MSFT_ARC_TEST` flag and is for testing only.
- Once the Defender extension is installed, alert behavior is identical to Azure VM SQL for the same simulations.

## Additional documentation

- [Architecture overview](docs/architecture.md)
- [Troubleshooting guide](docs/troubleshooting.md)
