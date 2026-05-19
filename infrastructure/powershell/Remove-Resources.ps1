#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
Removes the Azure resource group created for Defender for Cloud SQL testing.

.DESCRIPTION
Prompts for confirmation by default, removes the specified resource group and all contained resources,
and outputs the deletion request status. Use -Force to bypass the manual confirmation prompt.

.PARAMETER ResourceGroupName
Name of the Azure resource group to remove.

.PARAMETER Force
Skips the manual confirmation prompt before deletion.

.EXAMPLE
.\Remove-Resources.ps1 -ResourceGroupName 'rg-defender-test'

.EXAMPLE
.\Remove-Resources.ps1 -ResourceGroupName 'rg-defender-test' -Force -Confirm:$false
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

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

try {
    Ensure-AzConnection

    $resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if ($null -eq $resourceGroup) {
        Write-Verbose "Resource group '$ResourceGroupName' does not exist. Nothing to remove."
        [pscustomobject]@{
            ResourceGroupName = $ResourceGroupName
            Status            = 'NotFound'
        }
        return
    }

    if (-not $Force) {
        $confirmationMessage = "Remove resource group '$ResourceGroupName' and all contained resources?"
        $caption = 'Confirm resource group deletion'
        if (-not $PSCmdlet.ShouldContinue($confirmationMessage, $caption)) {
            Write-Verbose 'Deletion cancelled by user.'
            [pscustomobject]@{
                ResourceGroupName = $ResourceGroupName
                Status            = 'Cancelled'
            }
            return
        }
    }

    if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Remove Azure resource group')) {
        Write-Verbose "Submitting deletion request for resource group '$ResourceGroupName'."
        $removeSplat = @{
            Name        = $ResourceGroupName
            Force       = $true
            ErrorAction = 'Stop'
            Confirm     = $false
        }
        $null = Remove-AzResourceGroup @removeSplat
    }

    [pscustomobject]@{
        ResourceGroupName = $ResourceGroupName
        Status            = if ($WhatIfPreference) { 'WhatIf' } else { 'DeleteRequested' }
    }
}
catch {
    Write-Error "Failed to remove resource group: $($_.Exception.Message)"
    throw
}
