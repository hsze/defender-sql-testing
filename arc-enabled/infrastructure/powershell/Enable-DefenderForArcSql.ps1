#Requires -Modules Az.Accounts, Az.Resources, Az.ConnectedMachine, Az.Security

<#
.SYNOPSIS
Enables Microsoft Defender for SQL on Arc-connected machines and validates extension health.

.DESCRIPTION
Enables the Defender for SQL servers on machines plan at subscription scope. When an Arc machine
resource is provided, the script validates that the Arc SQL extension and the Defender for SQL
extension are present and healthy, waits for SQL discovery to complete, and returns a consolidated
protection summary suitable for test-lab verification.

.PARAMETER SubscriptionId
Azure subscription identifier where Defender for SQL on machines should be enabled.

.PARAMETER ArcMachineResourceId
Optional Azure resource ID of a specific Arc-enabled machine to validate after enabling the plan.

.EXAMPLE
.\Enable-DefenderForArcSql.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000' -Verbose

.EXAMPLE
.\Enable-DefenderForArcSql.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000' -ArcMachineResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-arc-sql/providers/Microsoft.HybridCompute/machines/sql-arc-vm' -Verbose
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ArcMachineResourceId
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

function Get-ArcMachineFromResourceId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceId
    )

    $resource = Get-AzResource -ResourceId $ResourceId -ExpandProperties -ErrorAction Stop
    [pscustomobject]@{
        Name              = $resource.Name
        ResourceGroupName = $resource.ResourceGroupName
        Id                = $resource.ResourceId
        Location          = $resource.Location
    }
}

function Wait-ForExtensions {
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
        $extensions = Get-AzConnectedMachineExtension -ResourceGroupName $ResourceGroupName -MachineName $MachineName -ErrorAction SilentlyContinue
        $sqlExtension = $extensions | Where-Object { $_.Publisher -eq 'Microsoft.AzureData' -and $_.ExtensionType -eq 'WindowsAgent.SqlServer' } | Select-Object -First 1
        $defenderExtension = $extensions | Where-Object { $_.Publisher -eq 'Microsoft.Azure.AzureDefenderForSQL' -and $_.ExtensionType -eq 'AdvancedThreatProtection.Windows' } | Select-Object -First 1

        if ($null -ne $sqlExtension -and $null -ne $defenderExtension) {
            return [pscustomobject]@{
                SqlExtension      = $sqlExtension
                DefenderExtension = $defenderExtension
            }
        }

        Start-Sleep -Seconds 30
    }
    while ((Get-Date) -lt $deadline)

    return [pscustomobject]@{
        SqlExtension      = $sqlExtension
        DefenderExtension = $defenderExtension
    }
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
        $sqlInstance = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.AzureData/SqlServerInstances' -ExpandProperties -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$MachineName*" -or $_.Properties.containerResourceId -like "*/$MachineName" } |
            Select-Object -First 1

        if ($null -ne $sqlInstance) {
            return $sqlInstance
        }

        Start-Sleep -Seconds 30
    }
    while ((Get-Date) -lt $deadline)

    return $null
}

try {
    Ensure-AzConnection
    $null = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop

    if ($PSCmdlet.ShouldProcess($SubscriptionId, 'Enable Defender for SQL servers on machines plan')) {
        $pricingSplat = @{
            Name        = 'SqlServerVirtualMachines'
            PricingTier = 'Standard'
            Confirm     = $false
            ErrorAction = 'Stop'
        }
        $null = Set-AzSecurityPricing @pricingSplat
    }

    $pricing = Get-AzSecurityPricing -Name 'SqlServerVirtualMachines' -ErrorAction Stop
    if (-not $ArcMachineResourceId) {
        [pscustomobject]@{
            SubscriptionId = $SubscriptionId
            PlanName       = 'SqlServerVirtualMachines'
            PricingTier    = $pricing.PricingTier
            Status         = if ($pricing.PricingTier -eq 'Standard') { 'Enabled' } else { 'NotEnabled' }
        }
        return
    }

    $machine = Get-ArcMachineFromResourceId -ResourceId $ArcMachineResourceId
    Write-Verbose "Waiting for required Arc extensions on machine '$($machine.Name)'."
    $extensionState = Wait-ForExtensions -ResourceGroupName $machine.ResourceGroupName -MachineName $machine.Name
    $sqlInstance = Wait-ForSqlInstance -ResourceGroupName $machine.ResourceGroupName -MachineName $machine.Name

    $sqlExtensionHealthy = $false
    $defenderExtensionHealthy = $false

    if ($null -ne $extensionState.SqlExtension) {
        $sqlExtensionHealthy = $extensionState.SqlExtension.ProvisioningState -eq 'Succeeded'
    }

    if ($null -ne $extensionState.DefenderExtension) {
        $defenderExtensionHealthy = $extensionState.DefenderExtension.ProvisioningState -eq 'Succeeded'
    }

    $protectionStatus = if ($pricing.PricingTier -eq 'Standard' -and $sqlExtensionHealthy -and $defenderExtensionHealthy -and $null -ne $sqlInstance) {
        'Protected'
    }
    elseif ($pricing.PricingTier -eq 'Standard') {
        'PendingExtensions'
    }
    else {
        'NotProtected'
    }

    [pscustomobject]@{
        SubscriptionId          = $SubscriptionId
        ArcMachineResourceId    = $machine.Id
        ArcMachineName          = $machine.Name
        DefenderPlanTier        = $pricing.PricingTier
        ProtectionStatus        = $protectionStatus
        SqlExtensionPublisher   = $extensionState.SqlExtension.Publisher
        SqlExtensionType        = $extensionState.SqlExtension.ExtensionType
        SqlExtensionState       = $extensionState.SqlExtension.ProvisioningState
        DefenderExtensionPublisher = $extensionState.DefenderExtension.Publisher
        DefenderExtensionType   = $extensionState.DefenderExtension.ExtensionType
        DefenderExtensionState  = $extensionState.DefenderExtension.ProvisioningState
        SqlInstanceResourceId   = $sqlInstance.ResourceId
        SqlInstanceName         = $sqlInstance.Name
    }
}
catch {
    Write-Error "Failed to enable Defender for Arc SQL: $($_.Exception.Message)"
    throw
}
