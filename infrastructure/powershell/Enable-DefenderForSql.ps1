#Requires -Modules Az.Accounts, Az.Security

<#
.SYNOPSIS
Enables Defender for SQL plans in the target subscription.

.DESCRIPTION
Sets Microsoft Defender for SQL servers on machines and Azure SQL Databases to the Standard pricing tier,
verifies the resulting status, and outputs the current pricing information for both plans.

.PARAMETER SubscriptionId
Azure subscription identifier where Defender plans should be enabled.

.EXAMPLE
.\Enable-DefenderForSql.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000' -Verbose

.EXAMPLE
.\Enable-DefenderForSql.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000' -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId
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

    Write-Verbose "Selecting subscription '$SubscriptionId'."
    $null = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop

    $plans = @(
        @{ Name = 'SqlServerVirtualMachines'; Description = 'Microsoft Defender for SQL servers on machines' },
        @{ Name = 'SqlServers'; Description = 'Microsoft Defender for Azure SQL Databases' }
    )

    foreach ($plan in $plans) {
        if ($PSCmdlet.ShouldProcess($plan.Name, "Enable $($plan.Description)")) {
            $pricingSplat = @{
                Name        = $plan.Name
                PricingTier = 'Standard'
                ErrorAction = 'Stop'
                Confirm     = $false
            }
            $null = Set-AzSecurityPricing @pricingSplat
        }
    }

    $results = foreach ($plan in $plans) {
        Write-Verbose "Retrieving current pricing for '$($plan.Name)'."
        $pricing = Get-AzSecurityPricing -Name $plan.Name -ErrorAction Stop
        [pscustomobject]@{
            SubscriptionId = $SubscriptionId
            PlanName       = $plan.Name
            Description    = $plan.Description
            PricingTier    = $pricing.PricingTier
            FreeTrialRemainingTime = $pricing.FreeTrialRemainingTime
            SubPlan        = $pricing.SubPlan
            Status         = if ($pricing.PricingTier -eq 'Standard') { 'Enabled' } else { 'NotEnabled' }
        }
    }

    $results
}
catch {
    Write-Error "Failed to enable Defender for SQL plans: $($_.Exception.Message)"
    throw
}
