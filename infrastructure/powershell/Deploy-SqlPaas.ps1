#Requires -Modules Az.Accounts, Az.Resources, Az.Sql, Az.Security

<#
.SYNOPSIS
Deploys an Azure SQL Database for Defender for Cloud testing.

.DESCRIPTION
Creates or reuses an Azure resource group, deploys an Azure SQL logical server and test database,
configures firewall rules for Azure services and the current client IP when discoverable, enables Defender
for SQL, and outputs a ready-to-use connection string template.

.PARAMETER ResourceGroupName
Name of the Azure resource group to create or reuse.

.PARAMETER Location
Azure region for the deployment.

.PARAMETER ServerName
Name of the Azure SQL logical server.

.PARAMETER DatabaseName
Name of the Azure SQL Database. Defaults to testdb.

.PARAMETER AdminUsername
SQL administrator username.

.PARAMETER AdminPassword
SQL administrator password.

.EXAMPLE
$adminPassword = Read-Host 'SQL admin password' -AsSecureString
.\Deploy-SqlPaas.ps1 -ResourceGroupName 'rg-defender-test' -Location 'eastus' -ServerName 'defendersqltest01' -DatabaseName 'testdb' -AdminUsername 'sqladminuser' -AdminPassword $adminPassword -Verbose

.EXAMPLE
.\Deploy-SqlPaas.ps1 -ResourceGroupName 'rg-defender-test' -Location 'eastus' -ServerName 'defendersqltest01' -AdminUsername 'sqladminuser' -AdminPassword $adminPassword -WhatIf
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
    [ValidatePattern('^[a-z0-9-]{3,63}$')]
    [string]$ServerName,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_-]{1,128}$')]
    [string]$DatabaseName = 'testdb',

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

    $server = Get-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $ServerName -ErrorAction SilentlyContinue
    if ($null -eq $server) {
        if ($PSCmdlet.ShouldProcess($ServerName, 'Create Azure SQL logical server')) {
            Write-Verbose "Creating Azure SQL logical server '$ServerName'."
            $serverSplat = @{
                ResourceGroupName          = $ResourceGroupName
                ServerName                 = $ServerName
                Location                   = $Location
                SqlAdministratorCredentials = $adminCredential
                ErrorAction                = 'Stop'
            }
            $server = New-AzSqlServer @serverSplat
        }
    }
    else {
        Write-Verbose "Using existing Azure SQL logical server '$ServerName'."
    }

    if ($null -eq $server) {
        throw "Azure SQL logical server '$ServerName' could not be resolved after deployment."
    }

    $database = Get-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $ServerName -DatabaseName $DatabaseName -ErrorAction SilentlyContinue
    if ($null -eq $database) {
        if ($PSCmdlet.ShouldProcess($DatabaseName, 'Create Azure SQL Database')) {
            Write-Verbose "Creating Azure SQL database '$DatabaseName' on server '$ServerName'."
            $databaseSplat = @{
                ResourceGroupName            = $ResourceGroupName
                ServerName                   = $ServerName
                DatabaseName                 = $DatabaseName
                RequestedServiceObjectiveName = 'Basic'
                ErrorAction                  = 'Stop'
            }
            $database = New-AzSqlDatabase @databaseSplat
        }
    }
    else {
        Write-Verbose "Using existing database '$DatabaseName'."
    }

    if ($PSCmdlet.ShouldProcess($ServerName, 'Create Azure services firewall rule')) {
        $azureServicesRule = Get-AzSqlServerFirewallRule -ResourceGroupName $ResourceGroupName -ServerName $ServerName -FirewallRuleName 'AllowAzureServices' -ErrorAction SilentlyContinue
        if ($null -eq $azureServicesRule) {
            $firewallSplat = @{
                ResourceGroupName = $ResourceGroupName
                ServerName        = $ServerName
                FirewallRuleName  = 'AllowAzureServices'
                StartIpAddress    = '0.0.0.0'
                EndIpAddress      = '0.0.0.0'
                ErrorAction       = 'Stop'
            }
            $null = New-AzSqlServerFirewallRule @firewallSplat
        }
        else {
            Write-Verbose 'Azure services firewall rule already exists.'
        }
    }

    $clientIpAddress = $null
    try {
        Write-Verbose 'Attempting to discover the current public client IP address.'
        $clientIpAddress = (Invoke-RestMethod -Method Get -Uri 'https://api.ipify.org?format=json' -ErrorAction Stop).ip
    }
    catch {
        Write-Verbose 'Current client IP address could not be determined. Skipping optional client firewall rule.'
    }

    if ($clientIpAddress -and $PSCmdlet.ShouldProcess($ServerName, "Create client firewall rule for $clientIpAddress")) {
        $clientRule = Get-AzSqlServerFirewallRule -ResourceGroupName $ResourceGroupName -ServerName $ServerName -FirewallRuleName 'AllowCurrentClientIp' -ErrorAction SilentlyContinue
        if ($null -eq $clientRule) {
            $clientRuleSplat = @{
                ResourceGroupName = $ResourceGroupName
                ServerName        = $ServerName
                FirewallRuleName  = 'AllowCurrentClientIp'
                StartIpAddress    = $clientIpAddress
                EndIpAddress      = $clientIpAddress
                ErrorAction       = 'Stop'
            }
            $null = New-AzSqlServerFirewallRule @clientRuleSplat
        }
        else {
            Write-Verbose 'Current client firewall rule already exists.'
        }
    }

    if ($PSCmdlet.ShouldProcess($ServerName, 'Enable Defender for SQL plan')) {
        $pricingSplat = @{
            Name        = 'SqlServers'
            PricingTier = 'Standard'
            ErrorAction = 'Stop'
            Confirm     = $false
        }
        $null = Set-AzSecurityPricing @pricingSplat
    }

    if ($PSCmdlet.ShouldProcess($ServerName, 'Enable Advanced Threat Protection')) {
        $atpSplat = @{
            ResourceGroupName = $ResourceGroupName
            ServerName        = $ServerName
            State             = 'Enabled'
            ErrorAction       = 'Stop'
            Confirm           = $false
        }
        $null = Set-AzSqlServerAdvancedThreatProtectionSetting @atpSplat
    }

    $fqdn = "$ServerName.database.windows.net"
    [pscustomobject]@{
        ResourceGroupName   = $ResourceGroupName
        ServerName          = $ServerName
        FullyQualifiedName  = $fqdn
        DatabaseName        = $DatabaseName
        AdminUsername       = $AdminUsername
        ClientIpAddress     = $clientIpAddress
        ConnectionString    = "Server=tcp:$fqdn,1433;Initial Catalog=$DatabaseName;Persist Security Info=False;User ID=$AdminUsername;Password=<password>;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
    }
}
catch {
    Write-Error "Deployment failed: $($_.Exception.Message)"
    throw
}
