#Requires -Modules Az.Accounts, Az.Resources, Az.Compute, Az.ConnectedMachine

<#
.SYNOPSIS
Cleans up Arc-enabled SQL Server test resources.

.DESCRIPTION
Best-effort disconnects the Azure Arc agent from the guest machine, removes the Arc machine resource,
and submits deletion for the Azure resource groups used by either the nested Hyper-V or quick-test
Arc SQL workflows. Confirmation is required unless -Force is supplied.

.PARAMETER ResourceGroupName
Primary Azure resource group to remove. For the quick-test workflow this is the VM resource group.

.PARAMETER HostResourceGroupName
Optional resource group for the Azure Hyper-V host when the nested virtualization workflow was used.

.PARAMETER ArcMachineResourceId
Optional Arc machine resource ID to disconnect and remove before resource group cleanup.

.PARAMETER Force
Skips the manual confirmation prompt.

.EXAMPLE
.\Remove-ArcResources.ps1 -ResourceGroupName 'rg-arc-sql' -HostResourceGroupName 'rg-arc-host' -ArcMachineResourceId '/subscriptions/.../providers/Microsoft.HybridCompute/machines/sql-arc-vm'

.EXAMPLE
.\Remove-ArcResources.ps1 -ResourceGroupName 'rg-arc-quick' -ArcMachineResourceId '/subscriptions/.../providers/Microsoft.HybridCompute/machines/arc-quick-sql' -Force -Confirm:$false
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$HostResourceGroupName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ArcMachineResourceId,

    [Parameter()]
    [switch]$Force
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

function Invoke-BestEffortVmDisconnect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VmName,

        [Parameter(Mandatory)]
        [string]$ScriptString
    )

    try {
        $runCommandSplat = @{
            ResourceGroupName = $ResourceGroupName
            VMName            = $VmName
            CommandId         = 'RunPowerShellScript'
            ScriptString      = $ScriptString
            ErrorAction       = 'Stop'
        }
        $null = Invoke-AzVMRunCommand @runCommandSplat
        return $true
    }
    catch {
        Write-Verbose "Disconnect attempt on VM '$VmName' failed: $($_.Exception.Message)"
        return $false
    }
}

try {
    Ensure-AzConnection

    if (-not $ResourceGroupName -and -not $HostResourceGroupName -and -not $ArcMachineResourceId) {
        throw 'Specify at least one of ResourceGroupName, HostResourceGroupName, or ArcMachineResourceId.'
    }

    $arcMachine = $null
    if ($ArcMachineResourceId) {
        $arcMachine = Get-AzResource -ResourceId $ArcMachineResourceId -ExpandProperties -ErrorAction SilentlyContinue
    }

    if (-not $Force) {
        $targets = @($ResourceGroupName, $HostResourceGroupName, $ArcMachineResourceId) | Where-Object { $_ }
        $message = "Remove the following Arc test resources: $($targets -join ', ')?"
        if (-not $PSCmdlet.ShouldContinue($message, 'Confirm Arc SQL test cleanup')) {
            [pscustomobject]@{
                Status = 'Cancelled'
            }
            return
        }
    }

    $disconnectStatus = 'Skipped'
    if ($arcMachine) {
        $machineName = $arcMachine.Name

        if ($HostResourceGroupName) {
            $hostVms = Get-AzVM -ResourceGroupName $HostResourceGroupName -ErrorAction SilentlyContinue
            foreach ($hostVm in $hostVms) {
                $nestedDisconnectScript = @"
`$ErrorActionPreference = 'Continue'
`$credPath = "C:\NestedSqlLab\State\$machineName-admin.xml"
if (Test-Path `$credPath) {
    try {
        `$credential = Import-Clixml -Path `$credPath
        Invoke-Command -VMName '$machineName' -Credential `$credential -ScriptBlock {
            `$agentPath = 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe'
            if (Test-Path `$agentPath) {
                & `$agentPath disconnect --force-local-only
            }
        } -ErrorAction Stop | Out-Null
    }
    catch {
    }
}
"@
                if (Invoke-BestEffortVmDisconnect -ResourceGroupName $HostResourceGroupName -VmName $hostVm.Name -ScriptString $nestedDisconnectScript) {
                    $disconnectStatus = 'NestedDisconnectRequested'
                    break
                }
            }
        }

        if ($disconnectStatus -eq 'Skipped' -and $ResourceGroupName) {
            $directVm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $machineName -ErrorAction SilentlyContinue
            if ($directVm) {
                $directDisconnectScript = @"
`$ErrorActionPreference = 'Continue'
`$agentPath = 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe'
if (Test-Path `$agentPath) {
    & `$agentPath disconnect --force-local-only
}
"@
                if (Invoke-BestEffortVmDisconnect -ResourceGroupName $ResourceGroupName -VmName $machineName -ScriptString $directDisconnectScript) {
                    $disconnectStatus = 'VmDisconnectRequested'
                }
            }
        }

        if ($PSCmdlet.ShouldProcess($ArcMachineResourceId, 'Remove Arc machine resource')) {
            Remove-AzResource -ResourceId $ArcMachineResourceId -Force -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }

    $resourceGroups = @($ResourceGroupName, $HostResourceGroupName) | Where-Object { $_ } | Select-Object -Unique
    foreach ($rgName in $resourceGroups) {
        $existingRg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
        if ($existingRg -and $PSCmdlet.ShouldProcess($rgName, 'Remove Azure resource group')) {
            $removeRgSplat = @{
                Name        = $rgName
                Force       = $true
                Confirm     = $false
                ErrorAction = 'Stop'
            }
            $null = Remove-AzResourceGroup @removeRgSplat
        }
    }

    [pscustomobject]@{
        ArcMachineResourceId   = $ArcMachineResourceId
        ArcMachineRemoved      = if ($ArcMachineResourceId) { $true } else { $false }
        ArcDisconnectStatus    = $disconnectStatus
        ResourceGroupsRemoved  = $resourceGroups -join ', '
        Status                 = if ($WhatIfPreference) { 'WhatIf' } else { 'DeleteRequested' }
    }
}
catch {
    Write-Error "Failed to remove Arc resources: $($_.Exception.Message)"
    throw
}
