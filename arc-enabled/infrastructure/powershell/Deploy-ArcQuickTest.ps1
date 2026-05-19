#Requires -Modules Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.ConnectedMachine

<#
.SYNOPSIS
Deploys a quick-test Azure SQL VM and force-enables Azure Arc onboarding for alert simulation testing.

.DESCRIPTION
Creates a standard Azure VM with SQL Server 2022 Developer edition, configures SQL Authentication,
sets the unsupported MSFT_ARC_TEST override that allows Azure Arc onboarding on an Azure VM, installs
Azure Arc, and ensures the Arc SQL extension discovers the SQL instance. This workflow is intended only
for test labs that need Arc-like behavior for Defender for SQL alert simulation.

.PARAMETER ResourceGroupName
Resource group that will contain the Azure VM and Arc machine metadata.

.PARAMETER Location
Azure region for the deployment.

.PARAMETER VmName
Name of the Azure VM.

.PARAMETER AdminUsername
Local administrator username for the VM.

.PARAMETER AdminPassword
Local administrator password for the VM.

.PARAMETER SqlAuthUsername
SQL Authentication login created for testing.

.PARAMETER SqlAuthPassword
Password for the SQL Authentication login.

.PARAMETER SubscriptionId
Azure subscription identifier used for the Arc registration.

.PARAMETER TenantId
Microsoft Entra tenant identifier used for the Arc registration.

.PARAMETER ServicePrincipalId
Client ID of the service principal used for Arc onboarding.

.PARAMETER ServicePrincipalSecret
Client secret of the service principal used for Arc onboarding.

.EXAMPLE
$adminPassword = Read-Host 'VM password' -AsSecureString
$sqlPassword = Read-Host 'SQL password' -AsSecureString
$spSecret = Read-Host 'SP secret' -AsSecureString
.\Deploy-ArcQuickTest.ps1 -ResourceGroupName 'rg-arc-quick' -Location 'eastus' -VmName 'arc-quick-sql' -AdminUsername 'azureadmin' -AdminPassword $adminPassword -SqlAuthUsername 'sqltester' -SqlAuthPassword $sqlPassword -SubscriptionId '00000000-0000-0000-0000-000000000000' -TenantId '11111111-1111-1111-1111-111111111111' -ServicePrincipalId '22222222-2222-2222-2222-222222222222' -ServicePrincipalSecret $spSecret -Verbose
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
    [securestring]$SqlAuthPassword,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ServicePrincipalId,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [securestring]$ServicePrincipalSecret
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
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
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
            $rgSplat = @{
                Name        = $Name
                Location    = $Region
                ErrorAction = 'Stop'
            }
            return New-AzResourceGroup @rgSplat
        }

        return [pscustomobject]@{ ResourceGroupName = $Name; Location = $Region }
    }

    $resourceGroup
}

function Register-ArcProviders {
    [CmdletBinding()]
    param()

    foreach ($providerNamespace in @('Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity', 'Microsoft.AzureArcData', 'Microsoft.AzureData')) {
        $provider = Get-AzResourceProvider -ProviderNamespace $providerNamespace -ErrorAction SilentlyContinue
        if ($null -eq $provider -or $provider.RegistrationState -ne 'Registered') {
            Register-AzResourceProvider -ProviderNamespace $providerNamespace -ErrorAction Stop | Out-Null
        }
    }
}

function Wait-ForArcMachine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$MachineName,

        [Parameter()]
        [int]$TimeoutSeconds = 1800
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $machine = Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName -Name $MachineName -ErrorAction SilentlyContinue
        if ($null -ne $machine) {
            return $machine
        }

        Start-Sleep -Seconds 30
    }
    while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for Arc machine '$MachineName'."
}

function Wait-ForSqlInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$MachineName,

        [Parameter()]
        [int]$TimeoutSeconds = 1800
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $resources = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.AzureData/SqlServerInstances' -ExpandProperties -ErrorAction SilentlyContinue
        $sqlInstance = $resources | Where-Object {
            $_.Name -like "$MachineName*" -or $_.Properties.containerResourceId -like "*/$MachineName"
        } | Select-Object -First 1

        if ($null -ne $sqlInstance) {
            return $sqlInstance
        }

        Start-Sleep -Seconds 30
    }
    while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for Arc SQL discovery on '$MachineName'."
}

try {
    Ensure-AzConnection
    $null = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    Ensure-ResourceGroup -Name $ResourceGroupName -Region $Location | Out-Null
    Register-ArcProviders

    $adminCredential = [pscredential]::new($AdminUsername, $AdminPassword)
    $plainSqlPassword = ConvertTo-PlainText -SecureString $SqlAuthPassword
    $plainSpSecret = ConvertTo-PlainText -SecureString $ServicePrincipalSecret
    $escapedSqlPassword = $plainSqlPassword.Replace("'", "''")
    $escapedSpSecret = $plainSpSecret.Replace("'", "''")
    $escapedSqlLogin = $SqlAuthUsername.Replace(']', ']]')

    $vnetName = "$VmName-vnet"
    $subnetName = 'default'
    $nsgName = "$VmName-nsg"
    $publicIpName = "$VmName-pip"
    $nicName = "$VmName-nic"

    $rdpRule = New-AzNetworkSecurityRuleConfig -Name 'Allow-RDP' -Description 'Allow RDP for test access' -Access Allow -Protocol Tcp -Direction Inbound -Priority 1000 -SourceAddressPrefix '*' -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange 3389
    $sqlRule = New-AzNetworkSecurityRuleConfig -Name 'Allow-SQL' -Description 'Allow SQL for test access' -Access Allow -Protocol Tcp -Direction Inbound -Priority 1010 -SourceAddressPrefix '*' -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange 1433

    $networkSecurityGroup = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($null -eq $networkSecurityGroup) {
        if ($PSCmdlet.ShouldProcess($nsgName, 'Create network security group')) {
            $nsgSplat = @{
                Name              = $nsgName
                ResourceGroupName = $ResourceGroupName
                Location          = $Location
                SecurityRules     = @($rdpRule, $sqlRule)
                ErrorAction       = 'Stop'
            }
            $networkSecurityGroup = New-AzNetworkSecurityGroup @nsgSplat
        }
    }

    $virtualNetwork = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($null -eq $virtualNetwork) {
        if ($PSCmdlet.ShouldProcess($vnetName, 'Create virtual network')) {
            $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix '10.30.0.0/24' -NetworkSecurityGroup $networkSecurityGroup
            $vnetSplat = @{
                Name              = $vnetName
                ResourceGroupName = $ResourceGroupName
                Location          = $Location
                AddressPrefix     = '10.30.0.0/16'
                Subnet            = $subnetConfig
                ErrorAction       = 'Stop'
            }
            $virtualNetwork = New-AzVirtualNetwork @vnetSplat
        }
    }

    $publicIp = Get-AzPublicIpAddress -Name $publicIpName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($null -eq $publicIp) {
        if ($PSCmdlet.ShouldProcess($publicIpName, 'Create public IP address')) {
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

    $vm = Get-AzVM -Name $VmName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($null -eq $vm) {
        if ($PSCmdlet.ShouldProcess($VmName, 'Deploy Azure SQL test VM')) {
            $vmConfig = New-AzVMConfig -VMName $VmName -VMSize 'Standard_D4s_v3'
            $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $VmName -Credential $adminCredential -ProvisionVMAgent -EnableAutoUpdate
            $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName 'MicrosoftSQLServer' -Offer 'sql2022-windows2022' -Skus 'developer' -Version 'latest'
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

    if ($PSCmdlet.ShouldProcess($VmName, 'Configure SQL authentication and enable Arc test override')) {
        $configureScript = @"
`$ErrorActionPreference = 'Stop'
[Environment]::SetEnvironmentVariable('MSFT_ARC_TEST', 'true', 'Machine')
`$env:MSFT_ARC_TEST = 'true'

`$instanceNames = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
`$instanceName = (`$instanceNames.PSObject.Properties | Select-Object -First 1).Name
if (-not `$instanceName) {
    throw 'No SQL Server instance was discovered on the VM.'
}

`$instanceId = `$instanceNames.`$instanceName
`$loginModePath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\`$instanceId\MSSQLServer"
Set-ItemProperty -Path `$loginModePath -Name 'LoginMode' -Value 2
Restart-Service -Name 'MSSQLSERVER' -Force

`$sqlStatement = @'
IF SUSER_ID(N'$escapedSqlLogin') IS NULL
BEGIN
    CREATE LOGIN [$escapedSqlLogin] WITH PASSWORD = N'$escapedSqlPassword', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
END
ELSE
BEGIN
    ALTER LOGIN [$escapedSqlLogin] WITH PASSWORD = N'$escapedSqlPassword';
END
IF IS_SRVROLEMEMBER('sysadmin', N'$escapedSqlLogin') <> 1
BEGIN
    ALTER SERVER ROLE [sysadmin] ADD MEMBER [$escapedSqlLogin];
END
'@

& sqlcmd.exe -S localhost -E -Q `$sqlStatement
if (`$LASTEXITCODE -ne 0) {
    throw 'sqlcmd.exe returned a non-zero exit code while creating the SQL login.'
}

if (-not (Get-NetFirewallRule -DisplayName 'Allow SQL Server 1433' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'Allow SQL Server 1433' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 | Out-Null
}

`$installerRoot = 'C:\Installers'
New-Item -ItemType Directory -Path `$installerRoot -Force | Out-Null
`$msiPath = Join-Path `$installerRoot 'AzureConnectedMachineAgent.msi'
if (-not (Test-Path `$msiPath)) {
    Invoke-WebRequest -Uri 'https://aka.ms/AzureConnectedMachineAgent' -OutFile `$msiPath -UseBasicParsing -ErrorAction Stop
}

`$installProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"`$msiPath`"", '/qn') -Wait -PassThru
if (`$installProcess.ExitCode -ne 0) {
    throw "Azure Connected Machine agent installation failed with exit code `$(`$installProcess.ExitCode)."
}

`$agentPath = 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe'
`$current = & `$agentPath show -j 2>`$null
if (`$LASTEXITCODE -eq 0 -and `$current) {
    `$currentState = `$current | ConvertFrom-Json
    if (`$currentState.status -eq 'Connected' -and `$currentState.resourceName -eq '$VmName') {
        return
    }

    if (`$currentState.status -eq 'Connected') {
        & `$agentPath disconnect --force-local-only
    }
}

& `$agentPath connect --service-principal-id '$ServicePrincipalId' --service-principal-secret '$escapedSpSecret' --resource-group '$ResourceGroupName' --tenant-id '$TenantId' --subscription-id '$SubscriptionId' --location '$Location' --cloud AzureCloud --resource-name '$VmName'
if (`$LASTEXITCODE -ne 0) {
    throw 'azcmagent connect returned a non-zero exit code.'
}
"@

        $runCommandSplat = @{
            ResourceGroupName = $ResourceGroupName
            VMName            = $VmName
            CommandId         = 'RunPowerShellScript'
            ScriptString      = $configureScript
            ErrorAction       = 'Stop'
        }
        $null = Invoke-AzVMRunCommand @runCommandSplat
    }

    $arcMachine = Wait-ForArcMachine -ResourceGroupName $ResourceGroupName -MachineName $VmName

    if ($PSCmdlet.ShouldProcess($VmName, 'Install Arc SQL extension')) {
        $extensionPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.HybridCompute/machines/$VmName/extensions/WindowsAgent.SqlServer?api-version=2023-10-03"
        $extensionPayload = @{
            location   = $Location
            properties = @{
                publisher                = 'Microsoft.AzureData'
                type                     = 'WindowsAgent.SqlServer'
                typeHandlerVersion       = '1.1'
                autoUpgradeMinorVersion  = $true
                enableAutomaticUpgrade   = $true
                settings                 = @{}
            }
        } | ConvertTo-Json -Depth 8

        $null = Invoke-AzRestMethod -Method PUT -Path $extensionPath -Payload $extensionPayload -ErrorAction Stop
    }

    $sqlInstance = Wait-ForSqlInstance -ResourceGroupName $ResourceGroupName -MachineName $VmName
    $publicIp = Get-AzPublicIpAddress -Name $publicIpName -ResourceGroupName $ResourceGroupName -ErrorAction Stop

    [pscustomobject]@{
        VmName               = $VmName
        VmResourceId         = $vm.Id
        PublicIpAddress      = $publicIp.IpAddress
        ArcMachineResourceId = $arcMachine.Id
        SqlInstanceResourceId = $sqlInstance.ResourceId
        SqlLogin             = $SqlAuthUsername
        SqlPort              = 1433
        SqlConnectionString  = "Server=tcp:$($publicIp.IpAddress),1433;Initial Catalog=master;Persist Security Info=False;User ID=$SqlAuthUsername;Password=<password>;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
        Note                 = 'MSFT_ARC_TEST=true is for testing only and is not supported for production use.'
    }
}
catch {
    Write-Error "Failed to deploy Arc quick-test VM: $($_.Exception.Message)"
    throw
}
