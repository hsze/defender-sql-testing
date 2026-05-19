#Requires -Modules Az.Accounts, Az.Resources, Az.Compute, Az.Network

<#
.SYNOPSIS
Deploys an Azure VM that can host nested Hyper-V workloads for Arc-enabled SQL Server testing.

.DESCRIPTION
Creates or reuses an Azure resource group, networking resources, and a Windows Server 2022 Datacenter VM
that supports nested virtualization. The script enables the Hyper-V role by using the Custom Script
Extension, configures an internal NAT switch for nested VM internet access, and returns RDP connection
information for follow-on nested SQL Server deployment.

.PARAMETER ResourceGroupName
Name of the Azure resource group that hosts the Hyper-V VM.

.PARAMETER Location
Azure region where the Hyper-V host should be deployed.

.PARAMETER VmName
Name of the Hyper-V host virtual machine.

.PARAMETER VmSize
Azure VM size. Use a size that supports nested virtualization such as Dv3, Dsv3, Ev3, or Esv3.

.PARAMETER AdminUsername
Local administrator username for the Hyper-V host.

.PARAMETER AdminPassword
Local administrator password for the Hyper-V host.

.EXAMPLE
$adminPassword = Read-Host 'Host password' -AsSecureString
.\Deploy-HyperVHost.ps1 -ResourceGroupName 'rg-arc-sql' -Location 'eastus' -AdminUsername 'azureadmin' -AdminPassword $adminPassword -Verbose

.EXAMPLE
.\Deploy-HyperVHost.ps1 -ResourceGroupName 'rg-arc-sql' -Location 'eastus' -VmSize 'Standard_E8s_v3' -AdminUsername 'azureadmin' -AdminPassword $adminPassword -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Location,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VmName = 'arc-hyperv-host',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VmSize = 'Standard_D8s_v3',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AdminUsername,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [securestring]$AdminPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-AzConnection {
    [CmdletBinding()]
    param()

    if (-not (Get-AzContext)) {
        Write-Verbose 'No Azure context detected. Connecting to Azure...'
        Connect-AzAccount -ErrorAction Stop | Out-Null
    }
}

function Ensure-ResourceGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Region
    )

    $resourceGroup = Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $resourceGroup) {
        if ($PSCmdlet.ShouldProcess($Name, 'Create resource group')) {
            Write-Verbose "Creating resource group '$Name' in '$Region'."
            $rgSplat = @{
                Name        = $Name
                Location    = $Region
                ErrorAction = 'Stop'
            }
            return New-AzResourceGroup @rgSplat
        }

        return [pscustomobject]@{ ResourceGroupName = $Name; Location = $Region }
    }

    Write-Verbose "Using existing resource group '$Name'."
    $resourceGroup
}

function Test-NestedVirtualizationVmSize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Size
    )

    $supportedPatterns = @(
        '^Standard_D\d+[a-z]*s?_v3$',
        '^Standard_E\d+[a-z]*s?_v3$',
        '^Standard_D\d+[a-z]*s?_v4$',
        '^Standard_E\d+[a-z]*s?_v4$'
    )

    foreach ($pattern in $supportedPatterns) {
        if ($Size -match $pattern) {
            return $true
        }
    }

    return $false
}

function Wait-ForVmRunCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VmName,

        [Parameter(Mandatory)]
        [string]$ScriptString,

        [Parameter()]
        [int]$TimeoutSeconds = 900,

        [Parameter()]
        [int]$RetryDelaySeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $runCommandSplat = @{
                ResourceGroupName = $ResourceGroupName
                VMName            = $VmName
                CommandId         = 'RunPowerShellScript'
                ScriptString      = $ScriptString
                ErrorAction       = 'Stop'
            }
            return Invoke-AzVMRunCommand @runCommandSplat
        }
        catch {
            if ((Get-Date) -ge $deadline) {
                throw
            }

            Write-Verbose "VM '$VmName' is still restarting or not ready for Run Command. Retrying in $RetryDelaySeconds seconds."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
    while ($true)
}

try {
    Ensure-AzConnection

    if (-not (Test-NestedVirtualizationVmSize -Size $VmSize)) {
        throw "VM size '$VmSize' is not in the supported nested virtualization families validated by this script. Use a Dv3/Dsv3/Ev3/Esv3-style size."
    }

    Ensure-ResourceGroup -Name $ResourceGroupName -Region $Location | Out-Null

    $vnetName = "$VmName-vnet"
    $subnetName = 'default'
    $nsgName = "$VmName-nsg"
    $publicIpName = "$VmName-pip"
    $nicName = "$VmName-nic"
    $natSwitchName = 'NestedNAT'
    $natPrefix = '172.16.0.0/24'
    $natGateway = '172.16.0.1'

    $rdpRule = New-AzNetworkSecurityRuleConfig -Name 'Allow-RDP' -Description 'Allow RDP to Hyper-V host' -Access Allow -Protocol Tcp -Direction Inbound -Priority 1000 -SourceAddressPrefix '*' -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange 3389

    $networkSecurityGroup = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($null -eq $networkSecurityGroup) {
        if ($PSCmdlet.ShouldProcess($nsgName, 'Create network security group')) {
            Write-Verbose "Creating network security group '$nsgName'."
            $nsgSplat = @{
                Name              = $nsgName
                ResourceGroupName = $ResourceGroupName
                Location          = $Location
                SecurityRules     = @($rdpRule)
                ErrorAction       = 'Stop'
            }
            $networkSecurityGroup = New-AzNetworkSecurityGroup @nsgSplat
        }
    }

    $virtualNetwork = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($null -eq $virtualNetwork) {
        if ($PSCmdlet.ShouldProcess($vnetName, 'Create virtual network')) {
            Write-Verbose "Creating virtual network '$vnetName'."
            $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix '10.20.0.0/24' -NetworkSecurityGroup $networkSecurityGroup
            $vnetSplat = @{
                Name              = $vnetName
                ResourceGroupName = $ResourceGroupName
                Location          = $Location
                AddressPrefix     = '10.20.0.0/16'
                Subnet            = $subnetConfig
                ErrorAction       = 'Stop'
            }
            $virtualNetwork = New-AzVirtualNetwork @vnetSplat
        }
    }

    $publicIp = Get-AzPublicIpAddress -Name $publicIpName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($null -eq $publicIp) {
        if ($PSCmdlet.ShouldProcess($publicIpName, 'Create public IP address')) {
            Write-Verbose "Creating public IP '$publicIpName'."
            $publicIpSplat = @{
                Name              = $publicIpName
                ResourceGroupName = $ResourceGroupName
                Location          = $Location
                AllocationMethod  = 'Static'
                Sku               = 'Standard'
                ErrorAction       = 'Stop'
            }
            $publicIp = New-AzPublicIpAddress @publicIpSplat
        }
    }

    $networkInterface = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($null -eq $networkInterface) {
        if ($PSCmdlet.ShouldProcess($nicName, 'Create network interface')) {
            Write-Verbose "Creating NIC '$nicName'."
            $nicSplat = @{
                Name                   = $nicName
                ResourceGroupName      = $ResourceGroupName
                Location               = $Location
                SubnetId               = $virtualNetwork.Subnets[0].Id
                PublicIpAddressId      = $publicIp.Id
                NetworkSecurityGroupId = $networkSecurityGroup.Id
                ErrorAction            = 'Stop'
            }
            $networkInterface = New-AzNetworkInterface @nicSplat
        }
    }

    $adminCredential = [pscredential]::new($AdminUsername, $AdminPassword)
    $vm = Get-AzVM -Name $VmName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($null -eq $vm) {
        if ($PSCmdlet.ShouldProcess($VmName, 'Deploy nested virtualization host VM')) {
            Write-Verbose "Deploying VM '$VmName' with size '$VmSize'."
            $vmConfig = New-AzVMConfig -VMName $VmName -VMSize $VmSize
            $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $VmName -Credential $adminCredential -ProvisionVMAgent -EnableAutoUpdate
            $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Skus '2022-datacenter' -Version 'latest'
            $vmConfig = Set-AzVMOSDisk -VM $vmConfig -StorageAccountType 'Premium_LRS' -Caching ReadWrite -CreateOption FromImage
            $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $networkInterface.Id
            $vmConfig.LicenseType = 'Windows_Server'

            $vmSplat = @{
                ResourceGroupName = $ResourceGroupName
                Location          = $Location
                VM                = $vmConfig
                ErrorAction       = 'Stop'
            }
            $null = New-AzVM @vmSplat
        }

        $vm = Get-AzVM -Name $VmName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    }
    else {
        Write-Verbose "Using existing VM '$VmName'."
    }

    $bootstrapScript = @"
`$ErrorActionPreference = 'Stop'
`$taskName = 'ConfigureNestedNat'
`$scriptPath = 'C:\Windows\Temp\ConfigureNestedNat.ps1'
`$scriptContent = @'
`$ErrorActionPreference = ''Stop''
`$switchName = '$natSwitchName'
`$natName = '$natSwitchName'
`$subnetPrefix = '$natPrefix'
`$gatewayAddress = '$natGateway'
if (-not (Get-VMSwitch -Name `$switchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name `$switchName -SwitchType Internal | Out-Null
}
`$adapter = Get-NetAdapter -Name "vEthernet (`$switchName)" -ErrorAction Stop
`$existingAddresses = Get-NetIPAddress -InterfaceIndex `$adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object IPAddress -ne '127.0.0.1'
if (`$existingAddresses) {
    `$existingAddresses | Remove-NetIPAddress -Confirm:`$false -ErrorAction SilentlyContinue
}
if (-not (Get-NetIPAddress -InterfaceIndex `$adapter.ifIndex -IPAddress `$gatewayAddress -ErrorAction SilentlyContinue)) {
    New-NetIPAddress -InterfaceIndex `$adapter.ifIndex -IPAddress `$gatewayAddress -PrefixLength 24 | Out-Null
}
if (-not (Get-NetNat -Name `$natName -ErrorAction SilentlyContinue)) {
    New-NetNat -Name `$natName -InternalIPInterfaceAddressPrefix `$subnetPrefix | Out-Null
}
if (Get-ScheduledTask -TaskName 'ConfigureNestedNat' -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName 'ConfigureNestedNat' -Confirm:`$false
}
'@
Set-Content -Path `$scriptPath -Value `$scriptContent -Encoding UTF8 -Force
`$action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-ExecutionPolicy Bypass -File ```"`$scriptPath```""
`$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName `$taskName -Action `$action -Trigger `$trigger -RunLevel Highest -Force | Out-Null
Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart
"@

    if ($PSCmdlet.ShouldProcess($VmName, 'Enable Hyper-V and configure nested NAT')) {
        Write-Verbose 'Configuring Hyper-V role through the Custom Script Extension.'
        $encodedBootstrap = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrapScript))
        $extensionSplat = @{
            ResourceGroupName         = $ResourceGroupName
            VMName                    = $VmName
            Location                  = $Location
            Name                      = 'EnableHyperV'
            Publisher                 = 'Microsoft.Compute'
            ExtensionType             = 'CustomScriptExtension'
            TypeHandlerVersion        = '1.10'
            AutoUpgradeMinorVersion   = $true
            Setting                   = @{ commandToExecute = "powershell.exe -ExecutionPolicy Bypass -EncodedCommand $encodedBootstrap" }
            ErrorAction               = 'Stop'
            Confirm                   = $false
        }
        $null = Set-AzVMExtension @extensionSplat

        Start-Sleep -Seconds 45
        $verificationScript = @"
`$ErrorActionPreference = 'Stop'
if ((Get-WindowsFeature -Name Hyper-V).InstallState -ne 'Installed') {
    throw 'Hyper-V role is not installed.'
}
`$switchName = '$natSwitchName'
`$natName = '$natSwitchName'
`$subnetPrefix = '$natPrefix'
`$gatewayAddress = '$natGateway'
if (-not (Get-VMSwitch -Name `$switchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name `$switchName -SwitchType Internal | Out-Null
}
`$adapter = Get-NetAdapter -Name "vEthernet (`$switchName)" -ErrorAction Stop
if (-not (Get-NetIPAddress -InterfaceIndex `$adapter.ifIndex -IPAddress `$gatewayAddress -ErrorAction SilentlyContinue)) {
    Get-NetIPAddress -InterfaceIndex `$adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:`$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex `$adapter.ifIndex -IPAddress `$gatewayAddress -PrefixLength 24 | Out-Null
}
if (-not (Get-NetNat -Name `$natName -ErrorAction SilentlyContinue)) {
    New-NetNat -Name `$natName -InternalIPInterfaceAddressPrefix `$subnetPrefix | Out-Null
}
[pscustomobject]@{
    HyperVInstalled = `$true
    NatSwitchName   = `$switchName
    NatGateway      = `$gatewayAddress
    NatPrefix       = `$subnetPrefix
} | ConvertTo-Json -Compress
"@
        $null = Wait-ForVmRunCommand -ResourceGroupName $ResourceGroupName -VmName $VmName -ScriptString $verificationScript
    }

    $publicIp = Get-AzPublicIpAddress -Name $publicIpName -ResourceGroupName $ResourceGroupName -ErrorAction Stop

    [pscustomobject]@{
        ResourceGroupName = $ResourceGroupName
        VmName            = $VmName
        VmResourceId      = $vm.Id
        PublicIpAddress   = $publicIp.IpAddress
        RdpTarget         = if ($publicIp.DnsSettings.Fqdn) { $publicIp.DnsSettings.Fqdn } else { $publicIp.IpAddress }
        RdpPort           = 3389
        RdpCommand        = "mstsc /v:$($publicIp.IpAddress)"
        NestedNatSwitch   = $natSwitchName
        NestedNatGateway  = $natGateway
        NestedSubnet      = $natPrefix
    }
}
catch {
    Write-Error "Failed to deploy Hyper-V host: $($_.Exception.Message)"
    throw
}
