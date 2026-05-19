#Requires -Modules Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Security, Az.SqlVirtualMachine

<#
.SYNOPSIS
Deploys SQL Server 2022 on an Azure virtual machine for Defender for Cloud testing.

.DESCRIPTION
Creates or reuses a resource group, deploys a Windows Server 2022 virtual machine with a SQL Server 2022 image,
registers the SQL IaaS extension, installs the Microsoft Defender for SQL extension, configures SQL Authentication,
and outputs connection details for follow-on testing.

.PARAMETER ResourceGroupName
Name of the Azure resource group to create or reuse.

.PARAMETER Location
Azure region for the deployment.

.PARAMETER VmName
Name of the Azure virtual machine.

.PARAMETER VmSize
Azure virtual machine size. Defaults to Standard_D4s_v3.

.PARAMETER AdminUsername
Local administrator username for the virtual machine.

.PARAMETER AdminPassword
Local administrator password for the virtual machine.

.PARAMETER SqlAuthUsername
SQL Authentication login to create for testing.

.PARAMETER SqlAuthPassword
Password for the SQL Authentication login.

.EXAMPLE
$adminPassword = Read-Host 'VM admin password' -AsSecureString
$sqlPassword = Read-Host 'SQL auth password' -AsSecureString
.\Deploy-SqlIaas.ps1 -ResourceGroupName 'rg-defender-test' -Location 'eastus' -VmName 'sqltestvm' -AdminUsername 'azureadmin' -AdminPassword $adminPassword -SqlAuthUsername 'sqltester' -SqlAuthPassword $sqlPassword -Verbose

.EXAMPLE
.\Deploy-SqlIaas.ps1 -ResourceGroupName 'rg-defender-test' -Location 'eastus' -VmName 'sqltestvm' -VmSize 'Standard_D8s_v5' -AdminUsername 'azureadmin' -AdminPassword $adminPassword -SqlAuthUsername 'sqltester' -SqlAuthPassword $sqlPassword -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Location,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VmName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VmSize = 'Standard_D4s_v3',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AdminUsername,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [securestring]$AdminPassword,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SqlAuthUsername,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [securestring]$SqlAuthPassword
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

function ConvertTo-PlainText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [securestring]$SecureString
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
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
            $resourceGroup = New-AzResourceGroup @rgSplat
        }
    }
    else {
        Write-Verbose "Using existing resource group '$Name'."
    }

    return $resourceGroup
}

try {
    Ensure-AzConnection
    Ensure-ResourceGroup -Name $ResourceGroupName -Region $Location | Out-Null

    $adminCredential = [pscredential]::new($AdminUsername, $AdminPassword)
    $plainSqlPassword = ConvertTo-PlainText -SecureString $SqlAuthPassword
    $escapedSqlPassword = $plainSqlPassword.Replace("'", "''")
    $escapedSqlLogin = $SqlAuthUsername.Replace(']', ']]')

    $vnetName = "$VmName-vnet"
    $subnetName = 'default'
    $nsgName = "$VmName-nsg"
    $publicIpName = "$VmName-pip"
    $nicName = "$VmName-nic"

    $virtualNetwork = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($null -eq $virtualNetwork) {
        Write-Verbose "Creating virtual network '$vnetName'."
        $rdpRule = New-AzNetworkSecurityRuleConfig -Name 'Allow-RDP' -Description 'Allow RDP for test access' -Access Allow -Protocol Tcp -Direction Inbound -Priority 1000 -SourceAddressPrefix '*' -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange 3389
        $sqlRule = New-AzNetworkSecurityRuleConfig -Name 'Allow-SQL' -Description 'Allow SQL for test access' -Access Allow -Protocol Tcp -Direction Inbound -Priority 1010 -SourceAddressPrefix '*' -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange 1433

        $nsgSplat = @{
            Name                  = $nsgName
            ResourceGroupName     = $ResourceGroupName
            Location              = $Location
            SecurityRules         = @($rdpRule, $sqlRule)
            ErrorAction           = 'Stop'
        }
        $networkSecurityGroup = New-AzNetworkSecurityGroup @nsgSplat

        $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix '10.10.0.0/24' -NetworkSecurityGroup $networkSecurityGroup

        $vnetSplat = @{
            Name              = $vnetName
            ResourceGroupName = $ResourceGroupName
            Location          = $Location
            AddressPrefix     = '10.10.0.0/16'
            Subnet            = $subnetConfig
            ErrorAction       = 'Stop'
        }
        $virtualNetwork = New-AzVirtualNetwork @vnetSplat

        $publicIpSplat = @{
            Name              = $publicIpName
            ResourceGroupName = $ResourceGroupName
            Location          = $Location
            AllocationMethod  = 'Static'
            Sku               = 'Standard'
            ErrorAction       = 'Stop'
        }
        $publicIp = New-AzPublicIpAddress @publicIpSplat

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
    else {
        Write-Verbose "Using existing virtual network '$vnetName'."
        $publicIp = Get-AzPublicIpAddress -Name $publicIpName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        $networkInterface = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue

        if ($null -eq $publicIp -or $null -eq $networkInterface) {
            throw "Existing network components for VM '$VmName' are incomplete. Expected resources '$publicIpName' and '$nicName'."
        }
    }

    $vm = Get-AzVM -Name $VmName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($null -eq $vm) {
        if ($PSCmdlet.ShouldProcess($VmName, 'Deploy SQL Server 2022 virtual machine')) {
            Write-Verbose "Deploying VM '$VmName' with SQL Server 2022 image."
            $vmConfig = New-AzVMConfig -VMName $VmName -VMSize $VmSize
            $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $VmName -Credential $adminCredential -ProvisionVMAgent -EnableAutoUpdate
            $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName 'MicrosoftSQLServer' -Offer 'sql2022-ws2022' -Skus 'sqldev-gen2' -Version 'latest'
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

        $vm = Get-AzVM -Name $VmName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    }
    else {
        Write-Verbose "Using existing VM '$VmName'."
    }

    if ($null -eq $vm) {
        throw "Virtual machine '$VmName' could not be resolved after deployment."
    }

    if ($PSCmdlet.ShouldProcess($VmName, 'Register SQL IaaS extension')) {
        $sqlVm = Get-AzSqlVM -Name $VmName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if ($null -eq $sqlVm) {
            $sqlVmSplat = @{
                Name              = $VmName
                ResourceGroupName = $ResourceGroupName
                Location          = $Location
                SqlManagementType = 'Full'
                LicenseType       = 'AHUB'
                ErrorAction       = 'Stop'
                Confirm           = $false
            }

            try {
                Write-Verbose 'Registering SQL VM with Azure Hybrid Benefit license type.'
                $null = New-AzSqlVM @sqlVmSplat
            }
            catch {
                Write-Warning 'Unable to register SQL VM with Azure Hybrid Benefit. Falling back to PAYG licensing.'
                $sqlVmSplat['LicenseType'] = 'PAYG'
                $null = New-AzSqlVM @sqlVmSplat
            }
        }
        else {
            Write-Verbose 'SQL IaaS extension is already registered.'
        }
    }

    if ($PSCmdlet.ShouldProcess($VmName, 'Install Microsoft Defender for SQL extension')) {
        $defenderExtension = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VmName -Name 'MicrosoftDefenderforSQL' -ErrorAction SilentlyContinue
        if ($null -eq $defenderExtension) {
            $extensionSplat = @{
                ResourceGroupName         = $ResourceGroupName
                VMName                    = $VmName
                Location                  = $Location
                Name                      = 'MicrosoftDefenderforSQL'
                Publisher                 = 'Microsoft.Azure.Security'
                ExtensionType             = 'SqlAdvancedThreatProtection'
                TypeHandlerVersion     = '1.0'
                ErrorAction            = 'Stop'
                Confirm                = $false
            }
            try {
                $null = Set-AzVMExtension @extensionSplat
            } catch {
                Write-Warning "Legacy 'SqlAdvancedThreatProtection' extension is no longer published. Skipping. Defender for SQL on machines is enabled via the pricing plan + Azure Monitor Agent. Error: $($_.Exception.Message)"
            }
        }
        else {
            Write-Verbose 'Microsoft Defender for SQL extension is already installed.'
        }
    }

    if ($PSCmdlet.ShouldProcess($VmName, 'Enable Defender for SQL pricing plan')) {
        $pricingSplat = @{
            Name        = 'SqlServerVirtualMachines'
            PricingTier = 'Standard'
            ErrorAction = 'Stop'
            Confirm     = $false
        }
        $null = Set-AzSecurityPricing @pricingSplat
    }

    if ($PSCmdlet.ShouldProcess($VmName, 'Enable Mixed Mode auth and open SQL firewall port')) {
        # Step 1: Switch SQL Server to Mixed Mode (LoginMode=2) and open port 1433.
        # On a fresh SQL Server 2022 image, SYSTEM is NOT a sysadmin, so we cannot
        # create SQL logins here directly. Login bootstrap happens in step 2.
        $configureSqlScript = @"
`$ErrorActionPreference = 'Stop'

`$instanceNames = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
`$instanceName = (`$instanceNames.PSObject.Properties | Select-Object -First 1).Name
if (-not `$instanceName) {
    throw 'No SQL Server instance was discovered on the VM.'
}

`$instanceId = `$instanceNames.`$instanceName
`$loginModePath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\`$instanceId\MSSQLServer"
Set-ItemProperty -Path `$loginModePath -Name 'LoginMode' -Value 2

`$serviceName = if (`$instanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$`$instanceName" }
Restart-Service -Name `$serviceName -Force

if (-not (Get-NetFirewallRule -DisplayName 'Allow SQL Server 1433' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'Allow SQL Server 1433' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 | Out-Null
}
"@

        $runCommandSplat = @{
            ResourceGroupName = $ResourceGroupName
            VMName            = $VmName
            CommandId         = 'RunPowerShellScript'
            ScriptString      = $configureSqlScript
            ErrorAction       = 'Stop'
        }
        $null = Invoke-AzVMRunCommand @runCommandSplat
    }

    if ($PSCmdlet.ShouldProcess($VmName, 'Bootstrap SQL logins via single-user mode')) {
        # Step 2: Run Initialize-SqlLogins.ps1 on the VM. The script restarts SQL
        # in single-user mode so the bootstrap connection is automatically granted
        # sysadmin, then grants SYSTEM/Administrators sysadmin, enables `sa`,
        # creates the requested SQL login, and restarts SQL normally.
        $bootstrapScriptPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath '..\simulations\Initialize-SqlLogins.ps1'
        $bootstrapScriptPath = [System.IO.Path]::GetFullPath($bootstrapScriptPath)
        if (-not (Test-Path $bootstrapScriptPath)) {
            throw "Initialize-SqlLogins.ps1 not found at expected path: $bootstrapScriptPath"
        }

        $bootstrapSplat = @{
            ResourceGroupName = $ResourceGroupName
            VMName            = $VmName
            CommandId         = 'RunPowerShellScript'
            ScriptPath        = $bootstrapScriptPath
            Parameter         = @{
                SqlUser     = $SqlAuthUsername
                SqlPassword = $plainSqlPassword
            }
            ErrorAction       = 'Stop'
        }
        $bootstrapResult = Invoke-AzVMRunCommand @bootstrapSplat
        $bootstrapStdout = ($bootstrapResult.Value | Where-Object { $_.Code -like '*StdOut*' } | Select-Object -ExpandProperty Message) -join "`n"
        Write-Verbose "Initialize-SqlLogins.ps1 output:`n$bootstrapStdout"
        if ($bootstrapStdout -notmatch 'IAmSysadmin') {
            Write-Warning 'Initialize-SqlLogins.ps1 did not report final sysadmin verification. Review run-command output.'
        }
    }

    $publicIp = Get-AzPublicIpAddress -Name $publicIpName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    $fqdn = if ($publicIp.DnsSettings -and $publicIp.DnsSettings.Fqdn) { $publicIp.DnsSettings.Fqdn } else { $publicIp.IpAddress }
    $connectionTarget = if ($fqdn) { $fqdn } else { $publicIp.IpAddress }

    [pscustomobject]@{
        ResourceGroupName    = $ResourceGroupName
        VirtualMachineName   = $VmName
        PublicIpAddress      = $publicIp.IpAddress
        ServerName           = $connectionTarget
        SqlPort              = 1433
        SqlLogin             = $SqlAuthUsername
        SqlConnectionString  = "Server=tcp:$connectionTarget,1433;Initial Catalog=master;Persist Security Info=False;User ID=$SqlAuthUsername;Password=<password>;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
        RdpTarget            = $publicIp.IpAddress
    }
}
catch {
    Write-Error "Deployment failed: $($_.Exception.Message)"
    throw
}
