#Requires -Modules Az.Accounts, Az.Resources, Az.Compute, Az.ConnectedMachine

<#
.SYNOPSIS
Connects the nested SQL VM to Azure Arc and ensures the Arc SQL extension is registered.

.DESCRIPTION
Runs a bootstrap script on the Azure Hyper-V host that uses PowerShell Direct to reach the nested SQL
VM, installs the Azure Connected Machine agent, and connects the machine to Azure Arc by using a
service principal. After the Arc machine appears in Azure, the script validates the connection,
installs the SQL Server Arc extension, waits for SQL discovery, and returns the Arc resource IDs.

.PARAMETER HostResourceGroupName
Resource group that contains the Azure Hyper-V host VM.

.PARAMETER HostVmName
Name of the Azure Hyper-V host VM.

.PARAMETER NestedVmName
Name of the nested SQL VM created inside Hyper-V.

.PARAMETER SubscriptionId
Azure subscription identifier that should own the Arc machine resource.

.PARAMETER ResourceGroupName
Azure resource group that will contain the Arc-enabled machine resource.

.PARAMETER Location
Azure region for the Arc-enabled machine metadata.

.PARAMETER TenantId
Microsoft Entra tenant identifier for the Azure Arc connection.

.PARAMETER ServicePrincipalId
Client ID of the service principal used to onboard the Arc agent.

.PARAMETER ServicePrincipalSecret
Client secret of the service principal used to onboard the Arc agent.

.EXAMPLE
$secret = Read-Host 'Service principal secret' -AsSecureString
.\Connect-ArcAgent.ps1 -HostResourceGroupName 'rg-arc-sql' -HostVmName 'arc-hyperv-host' -NestedVmName 'sql-arc-vm' -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroupName 'rg-arc-sql' -Location 'eastus' -TenantId '11111111-1111-1111-1111-111111111111' -ServicePrincipalId '22222222-2222-2222-2222-222222222222' -ServicePrincipalSecret $secret -Verbose
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$HostResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$HostVmName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$NestedVmName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Location,

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

    $providers = @(
        'Microsoft.HybridCompute',
        'Microsoft.GuestConfiguration',
        'Microsoft.HybridConnectivity',
        'Microsoft.AzureArcData',
        'Microsoft.AzureData'
    )

    foreach ($providerNamespace in $providers) {
        Write-Verbose "Ensuring resource provider '$providerNamespace' is registered."
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
        [int]$TimeoutSeconds = 1800,

        [Parameter()]
        [int]$RetryDelaySeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $machine = Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName -Name $MachineName -ErrorAction SilentlyContinue
        if ($null -ne $machine) {
            return $machine
        }

        Start-Sleep -Seconds $RetryDelaySeconds
    }
    while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for Arc machine '$MachineName' in resource group '$ResourceGroupName'."
}

function Wait-ForSqlInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$MachineName,

        [Parameter()]
        [int]$TimeoutSeconds = 1800,

        [Parameter()]
        [int]$RetryDelaySeconds = 30
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

        Start-Sleep -Seconds $RetryDelaySeconds
    }
    while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for SQL discovery on Arc machine '$MachineName'."
}

try {
    Ensure-AzConnection
    $null = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    Ensure-ResourceGroup -Name $ResourceGroupName -Region $Location | Out-Null
    Register-ArcProviders

    $plainSecret = ConvertTo-PlainText -SecureString $ServicePrincipalSecret
    $escapedSecret = $plainSecret.Replace("'", "''")

    $bootstrapScript = @"
`$ErrorActionPreference = 'Stop'
`$credPath = "C:\NestedSqlLab\State\$NestedVmName-admin.xml"
if (-not (Test-Path `$credPath)) {
    throw "Credential state file '`$credPath' was not found on the host. Run Deploy-NestedSqlVm.ps1 first."
}

`$credential = Import-Clixml -Path `$credPath
`$session = `$null
`$deadline = (Get-Date).AddMinutes(15)
do {
    try {
        `$session = New-PSSession -VMName '$NestedVmName' -Credential `$credential -ErrorAction Stop
    }
    catch {
        Start-Sleep -Seconds 15
    }
}
while (`$null -eq `$session -and (Get-Date) -lt `$deadline)

if (`$null -eq `$session) {
    throw "Unable to establish PowerShell Direct connectivity to nested VM '$NestedVmName'."
}

try {
    Invoke-Command -Session `$session -ScriptBlock {
        param(
            [string]`$ArcResourceGroup,
            [string]`$ArcLocation,
            [string]`$ArcSubscriptionId,
            [string]`$ArcTenantId,
            [string]`$ArcSpnId,
            [string]`$ArcSpnSecret
        )

        `$ErrorActionPreference = 'Stop'
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
        if (-not (Test-Path `$agentPath)) {
            throw 'azcmagent.exe was not found after installation.'
        }

        `$showOutput = & `$agentPath show -j 2>`$null
        if (`$LASTEXITCODE -eq 0 -and `$showOutput) {
            `$currentState = `$showOutput | ConvertFrom-Json
            if (`$currentState.status -eq 'Connected' -and `$currentState.resourceName -eq '$NestedVmName') {
                return
            }

            if (`$currentState.status -eq 'Connected') {
                & `$agentPath disconnect --force-local-only
            }
        }

        `$connectArgs = @(
            'connect',
            '--service-principal-id', `$ArcSpnId,
            '--service-principal-secret', `$ArcSpnSecret,
            '--resource-group', `$ArcResourceGroup,
            '--tenant-id', `$ArcTenantId,
            '--subscription-id', `$ArcSubscriptionId,
            '--location', `$ArcLocation,
            '--cloud', 'AzureCloud',
            '--resource-name', '$NestedVmName'
        )

        & `$agentPath @connectArgs
        if (`$LASTEXITCODE -ne 0) {
            throw 'azcmagent connect returned a non-zero exit code.'
        }

        `$connectedState = & `$agentPath show -j | ConvertFrom-Json
        if (`$connectedState.status -ne 'Connected') {
            throw "azcmagent status is '`$(`$connectedState.status)' instead of 'Connected'."
        }
    } -ArgumentList '$ResourceGroupName', '$Location', '$SubscriptionId', '$TenantId', '$ServicePrincipalId', '$escapedSecret' | Out-Null
}
finally {
    if (`$session) {
        Remove-PSSession -Session `$session -ErrorAction SilentlyContinue
    }
}
"@

    if ($PSCmdlet.ShouldProcess($NestedVmName, 'Install Azure Arc agent on nested VM')) {
        Write-Verbose "Installing Azure Arc agent on nested VM '$NestedVmName' via host '$HostVmName'."
        $runCommandSplat = @{
            ResourceGroupName = $HostResourceGroupName
            VMName            = $HostVmName
            CommandId         = 'RunPowerShellScript'
            ScriptString      = $bootstrapScript
            ErrorAction       = 'Stop'
        }
        $null = Invoke-AzVMRunCommand @runCommandSplat
    }

    Write-Verbose "Waiting for Arc machine '$NestedVmName' to appear in Azure."
    $arcMachine = Wait-ForArcMachine -ResourceGroupName $ResourceGroupName -MachineName $NestedVmName

    if ($PSCmdlet.ShouldProcess($NestedVmName, 'Install Azure Arc SQL extension')) {
        Write-Verbose "Ensuring WindowsAgent.SqlServer extension exists on Arc machine '$NestedVmName'."
        $sqlExtensionPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.HybridCompute/machines/$NestedVmName/extensions/WindowsAgent.SqlServer?api-version=2023-10-03"
        $sqlExtensionPayload = @{
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

        $null = Invoke-AzRestMethod -Method PUT -Path $sqlExtensionPath -Payload $sqlExtensionPayload -ErrorAction Stop
    }

    $sqlInstance = Wait-ForSqlInstance -ResourceGroupName $ResourceGroupName -MachineName $NestedVmName

    [pscustomobject]@{
        ArcMachineName      = $NestedVmName
        ArcMachineResourceId = $arcMachine.Id
        ArcMachineStatus    = $arcMachine.Status
        SqlInstanceName     = $sqlInstance.Name
        SqlInstanceResourceId = $sqlInstance.ResourceId
    }
}
catch {
    Write-Error "Failed to connect the nested VM to Azure Arc: $($_.Exception.Message)"
    throw
}
