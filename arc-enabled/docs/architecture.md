# Architecture Overview

This section explains the two supported patterns for building an Arc-enabled SQL Server lab for Microsoft Defender for Cloud testing.

## Nested Hyper-V architecture

```text
Azure Subscription
    |
    +-- Azure Virtual Network
            |
            +-- Azure VM Host
                    - Hyper-V enabled
                    - Public IP for administration
                    - NAT configured for nested guest traffic
                    |
                    +-- Nested VM
                            - Windows Server or Windows client
                            - SQL Server
                            - Azure Arc agent
                            - SQL extension
                            - MicrosoftDefenderForSQL extension
                                    |
                                    v
                              Azure Arc
                                    |
                                    v
                         Defender for Cloud
```

This is the recommended layout because it most closely resembles an on-premises SQL Server that is projected into Azure through Azure Arc.

## Quick-test override architecture

```text
Azure Subscription
    |
    +-- Azure Virtual Network
            |
            +-- Azure VM
                    - SQL Server
                    - Azure Arc agent installed with MSFT_ARC_TEST=true
                    - SQL extension
                    - MicrosoftDefenderForSQL extension
                            |
                            v
                      Azure Arc
                            |
                            v
                 Defender for Cloud
```

This path is simpler and faster, but it is less representative of a real non-Azure machine because it uses a testing override during Arc onboarding.

## Networking model

### Host VM networking

For the nested approach, the Azure host VM has the externally reachable interface. It typically has:

- A NIC attached to an Azure virtual network
- A public IP for remote management, if required
- Outbound internet access to Azure services

### Nested VM networking

The nested VM uses an internal Hyper-V switch on the host VM. The host performs NAT so the nested guest can reach the internet. Typical flow:

1. Nested VM sends outbound traffic to its default gateway on the Hyper-V internal switch.
2. Host VM performs NAT.
3. Traffic exits through the host VM NIC to Azure and public Azure service endpoints.

The nested guest does not need its own Azure NIC or public IP. It only needs reliable outbound HTTPS connectivity to Azure.

## Arc agent registration flow

The Azure Arc agent runs on the SQL Server machine and connects outbound to Azure over HTTPS. The general flow is:

1. Arc agent is installed on the machine.
2. The machine authenticates using the configured onboarding method, often a service principal.
3. The machine registers in Azure as an Arc-enabled server resource.
4. Azure can then deploy extensions to that Arc machine.
5. SQL discovery and Defender protection features become available through extensions and policy.

This means inbound access from Azure to the SQL machine is not required for basic Arc registration. The critical dependency is outbound connectivity to Azure endpoints over port 443.

## Defender for SQL on Arc

Defender for SQL on Arc works by deploying the `MicrosoftDefenderForSQL` extension to the Arc-connected machine after the machine is onboarded and SQL Server is discovered.

High-level flow:

1. Machine is registered in Azure Arc.
2. SQL-related Arc extension discovers the local SQL instance.
3. Defender for Cloud recognizes the Arc-enabled SQL asset.
4. The `MicrosoftDefenderForSQL` extension is deployed.
5. Telemetry and protection data flow into Defender for Cloud.

## Extension responsibilities

The Defender-related extension and supporting SQL extension are responsible for the main protection workflow:

- Vulnerability assessment support for the SQL instance
- Advanced threat protection signal generation
- Telemetry collection needed by Defender for Cloud
- Health reporting so extension state can be monitored in Azure

When the extension is healthy, the simulation behavior and alert validation process match the existing `../simulations/` and `../kql/` workflow used elsewhere in the repository.
