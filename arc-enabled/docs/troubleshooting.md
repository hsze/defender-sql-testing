# Troubleshooting

Use this guide to diagnose the most common issues when building an Arc-enabled SQL Server lab for Defender for Cloud testing.

## Arc agent will not connect

Common causes:

- Outbound HTTPS on port 443 is blocked
- Proxy settings are missing or incorrect
- DNS resolution is failing
- The service principal or onboarding credentials are invalid

What to check:

- Confirm the machine can reach Azure service endpoints over 443
- Check local firewall and upstream network rules
- Validate proxy configuration if a proxy is required
- Verify DNS resolution from the machine
- Re-run Arc onboarding with known-good credentials

## Nested VM has no internet access

Common causes:

- Hyper-V internal switch was created but NAT was not configured
- The nested VM gateway or DNS settings are wrong
- IP forwarding or host firewall rules are blocking traffic

What to check:

- Confirm the nested VM has an IP address on the internal switch subnet
- Confirm the default gateway points to the host NAT interface
- Verify NAT exists on the host VM
- Test outbound HTTPS from the nested VM
- Validate DNS server settings inside the nested guest

## Hyper-V role will not install

Common causes:

- The selected Azure VM size does not support nested virtualization
- Virtualization was not exposed to the guest
- The host image or OS version does not support Hyper-V

What to check:

- Confirm the Azure VM SKU supports nested virtualization
- Use a supported Windows host operating system
- Verify virtualization extensions are available inside the host VM
- Redeploy with a supported VM size if needed

## SQL instance is not discovered by Arc

Common causes:

- SQL extension is not installed
- SQL Server service is stopped
- SQL instance is installed but not healthy
- The Arc machine is connected, but SQL resource discovery has not completed

What to check:

- Verify SQL Server services are running
- Confirm the SQL extension is installed on the Arc machine
- Check the Arc machine extension status in Azure
- Wait a few minutes and refresh the Azure portal

## Defender extension will not deploy

Common causes:

- Defender for SQL plan is not enabled
- The account lacks permission to deploy or manage extensions
- The Arc machine is unhealthy or disconnected
- SQL discovery has not completed yet

What to check:

- Confirm the correct Defender for Cloud plan is enabled
- Confirm permissions for the operator or automation account
- Verify the Arc machine is connected and healthy
- Verify the SQL instance is visible before expecting Defender extension deployment

## Alerts do not appear after simulation

Common causes:

- The `MicrosoftDefenderForSQL` extension is not healthy
- SQL discovery or protection onboarding is incomplete
- Telemetry processing is delayed
- The simulation ran before the extension finished provisioning

What to check:

- Confirm the Defender extension is installed and healthy
- Re-run the simulation after extension health is confirmed
- Allow time for telemetry processing
- Validate alerts with the existing `../kql/` queries

## Quick-test override error: Machine is already an Azure resource

This is specific to the `MSFT_ARC_TEST` method.

Cause:

- The Arc agent was installed before `MSFT_ARC_TEST=true` was set

Resolution:

1. Remove the partially installed or failed Arc agent.
2. Set `MSFT_ARC_TEST=true` before starting the Arc agent installation.
3. Reinstall the agent and retry onboarding.

## Check extension status

Use Azure CLI to review extension health on the Arc machine:

```powershell
az connectedmachine extension list --machine-name <arc-machine-name> --resource-group <resource-group>
```

Review the installed extensions and confirm that the SQL and Defender-related extensions report healthy or succeeded states.

## Verify Defender protection in Azure portal

To verify that protection is active:

1. Open the Arc-enabled machine or SQL resource in the Azure portal.
2. Open the Security or Defender for Cloud blade.
3. Confirm the SQL instance is discovered.
4. Confirm the Defender protection and extension status appear healthy.
5. Run a simulation and then validate alerts with the repository KQL queries.
