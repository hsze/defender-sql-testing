#Requires -Modules Az.Accounts, Az.Resources, Az.Compute

<#
.SYNOPSIS
Creates a nested Hyper-V VM on the Arc test host and installs SQL Server Developer edition.

.DESCRIPTION
Uses Invoke-AzVMRunCommand against the Azure Hyper-V host to create a nested Windows Server 2022
virtual machine, configure NAT networking, install SQL Server Developer edition silently, enable
mixed-mode authentication, and create a SQL login that can be used by the Defender simulations.

.PARAMETER HostResourceGroupName
Resource group that contains the Azure Hyper-V host VM.

.PARAMETER HostVmName
Name of the Azure Hyper-V host VM.

.PARAMETER NestedVmName
Name of the nested SQL Server VM created inside Hyper-V.

.PARAMETER SqlIsoUrl
Optional URL for SQL Server installation media. If omitted, the script downloads the SQL Server 2022
Developer bootstrapper and uses it to fetch ISO media.

.PARAMETER AdminUsername
Local administrator username for the nested VM.

.PARAMETER AdminPassword
Local administrator password for the nested VM.

.PARAMETER SqlAuthUsername
SQL Authentication login created for test simulations.

.PARAMETER SqlAuthPassword
Password assigned to the SQL Authentication login.

.EXAMPLE
$adminPassword = Read-Host 'Nested VM password' -AsSecureString
$sqlPassword = Read-Host 'SQL password' -AsSecureString
.\Deploy-NestedSqlVm.ps1 -HostResourceGroupName 'rg-arc-sql' -HostVmName 'arc-hyperv-host' -AdminUsername 'arcadmin' -AdminPassword $adminPassword -SqlAuthUsername 'sqltester' -SqlAuthPassword $sqlPassword -Verbose

.EXAMPLE
.\Deploy-NestedSqlVm.ps1 -HostResourceGroupName 'rg-arc-sql' -HostVmName 'arc-hyperv-host' -NestedVmName 'sql-arc-vm' -SqlIsoUrl 'https://contoso.blob.core.windows.net/install/sql.iso' -AdminUsername 'arcadmin' -AdminPassword $adminPassword -SqlAuthUsername 'sqltester' -SqlAuthPassword $sqlPassword -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$HostResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$HostVmName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$NestedVmName = 'sql-arc-vm',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SqlIsoUrl,

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
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

try {
    Ensure-AzConnection

    $null = Get-AzVM -ResourceGroupName $HostResourceGroupName -Name $HostVmName -ErrorAction Stop

    $plainAdminPassword = ConvertTo-PlainText -SecureString $AdminPassword
    $plainSqlPassword = ConvertTo-PlainText -SecureString $SqlAuthPassword
    $escapedAdminPassword = $plainAdminPassword.Replace("'", "''")
    $escapedSqlPassword = $plainSqlPassword.Replace("'", "''")
    $resolvedSqlIsoUrl = if ($PSBoundParameters.ContainsKey('SqlIsoUrl')) { $SqlIsoUrl } else { '' }

    $runCommandScript = @"
`$ErrorActionPreference = 'Stop'
`$labRoot = 'C:\NestedSqlLab'
`$stateRoot = Join-Path `$labRoot 'State'
`$vmRoot = Join-Path `$labRoot 'VMs'
`$mediaRoot = Join-Path `$labRoot 'Media'
`$vmName = '$NestedVmName'
`$adminUser = '$AdminUsername'
`$adminPassword = '$escapedAdminPassword'
`$sqlLogin = '$SqlAuthUsername'
`$sqlPassword = '$escapedSqlPassword'
`$sqlMediaUrl = '$resolvedSqlIsoUrl'
`$natSwitchName = 'NestedNAT'
`$natGateway = '172.16.0.1'
`$nestedIp = '172.16.0.10'
`$dnsServers = @('1.1.1.1', '8.8.8.8')
`$stateCredentialPath = Join-Path `$stateRoot "`$vmName-admin.xml"
`$stateMetadataPath = Join-Path `$stateRoot "`$vmName.json"
`$guestVhdPath = Join-Path `$vmRoot "`$vmName-os.vhdx"
`$guestRootPath = Join-Path `$vmRoot `$vmName
`$windowsIsoPath = Join-Path `$mediaRoot 'WindowsServer2022Eval.iso'

foreach (`$path in @(`$labRoot, `$stateRoot, `$vmRoot, `$mediaRoot)) {
    if (-not (Test-Path `$path)) {
        New-Item -ItemType Directory -Path `$path -Force | Out-Null
    }
}

if (-not (Get-VMSwitch -Name `$natSwitchName -ErrorAction SilentlyContinue)) {
    throw "The NAT switch '`$natSwitchName' does not exist on the host. Run Deploy-HyperVHost.ps1 first."
}

if (-not (Test-Path `$windowsIsoPath)) {
    `$windowsIsoCandidates = @(
        'https://go.microsoft.com/fwlink/?linkid=2195443',
        'https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso'
    )

    `$downloaded = `$false
    foreach (`$candidate in `$windowsIsoCandidates) {
        try {
            Invoke-WebRequest -Uri `$candidate -OutFile `$windowsIsoPath -UseBasicParsing -ErrorAction Stop
            if ((Get-Item `$windowsIsoPath).Length -gt 1GB) {
                `$downloaded = `$true
                break
            }

            Remove-Item `$windowsIsoPath -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Verbose "Unable to download Windows Server media from '`$candidate': `$(`$_.Exception.Message)"
        }
    }

    if (-not `$downloaded) {
        throw "Windows Server 2022 evaluation ISO is required. Download it from Microsoft Evaluation Center and place it at '`$windowsIsoPath', then rerun the script."
    }
}

`$secureAdminPassword = ConvertTo-SecureString `$adminPassword -AsPlainText -Force
`$guestCredential = [pscredential]::new(`$adminUser, `$secureAdminPassword)
`$guestCredential | Export-Clixml -Path `$stateCredentialPath -Force

if (-not (Test-Path `$guestVhdPath)) {
    `$mountedIso = Mount-DiskImage -ImagePath `$windowsIsoPath -PassThru -StorageType ISO -ErrorAction Stop
    try {
        `$isoVolume = `$mountedIso | Get-Volume
        `$sourceDrive = "`$(`$isoVolume.DriveLetter):\"
        `$imagePath = if (Test-Path (Join-Path `$sourceDrive 'sources\install.wim')) {
            Join-Path `$sourceDrive 'sources\install.wim'
        }
        else {
            Join-Path `$sourceDrive 'sources\install.esd'
        }

        `$imageInfo = Get-WindowsImage -ImagePath `$imagePath | Where-Object ImageName -match 'Datacenter.*Desktop Experience' | Select-Object -First 1
        if (`$null -eq `$imageInfo) {
            `$imageInfo = Get-WindowsImage -ImagePath `$imagePath | Select-Object -First 1
        }

        New-VHD -Path `$guestVhdPath -SizeBytes 60GB -Dynamic | Out-Null
        `$mountedVhd = Mount-VHD -Path `$guestVhdPath -Passthru -ErrorAction Stop
        try {
            `$disk = Initialize-Disk -Number `$mountedVhd.DiskNumber -PartitionStyle GPT -PassThru
            `$efiPartition = New-Partition -DiskNumber `$disk.Number -Size 100MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
            Format-Volume -Partition `$efiPartition -FileSystem FAT32 -NewFileSystemLabel 'SYSTEM' -Confirm:`$false | Out-Null
            `$msrPartition = New-Partition -DiskNumber `$disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
            `$null = `$msrPartition
            `$osPartition = New-Partition -DiskNumber `$disk.Number -UseMaximumSize -AssignDriveLetter
            Format-Volume -Partition `$osPartition -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:`$false | Out-Null

            `$efiVolume = `$efiPartition | Get-Volume
            `$osVolume = `$osPartition | Get-Volume
            `$windowsDrive = "`$(`$osVolume.DriveLetter):\"
            `$systemDrive = "`$(`$efiVolume.DriveLetter):"

            & dism.exe /Apply-Image /ImageFile:`$imagePath /Index:`$(`$imageInfo.ImageIndex) /ApplyDir:`$windowsDrive | Out-Null
            & bcdboot.exe "`$windowsDrive\Windows" /s `$systemDrive /f UEFI | Out-Null

            `$unattendPath = Join-Path `$windowsDrive 'Windows\Panther\Unattend.xml'
            New-Item -ItemType Directory -Path (Split-Path `$unattendPath -Parent) -Force | Out-Null
            `$unattendXml = @(
                "<?xml version='1.0' encoding='utf-8'?>",
                "<unattend xmlns='urn:schemas-microsoft-com:unattend'>",
                "  <settings pass='oobeSystem'>",
                "    <component name='Microsoft-Windows-Shell-Setup' processorArchitecture='amd64' publicKeyToken='31bf3856ad364e35' language='neutral' versionScope='nonSxS'>",
                "      <ComputerName>`$vmName</ComputerName>",
                "      <TimeZone>UTC</TimeZone>",
                "      <RegisteredOwner>DefenderSqlTesting</RegisteredOwner>",
                "      <UserAccounts>",
                "        <LocalAccounts>",
                "          <LocalAccount wcm:action='add' xmlns:wcm='http://schemas.microsoft.com/WMIConfig/2002/State'>",
                "            <Name>`$adminUser</Name>",
                "            <DisplayName>`$adminUser</DisplayName>",
                "            <Group>Administrators</Group>",
                "            <Password>",
                "              <Value>`$adminPassword</Value>",
                "              <PlainText>true</PlainText>",
                "            </Password>",
                "          </LocalAccount>",
                "        </LocalAccounts>",
                "      </UserAccounts>",
                "      <AutoLogon>",
                "        <Enabled>true</Enabled>",
                "        <LogonCount>1</LogonCount>",
                "        <Username>`$adminUser</Username>",
                "        <Password>",
                "          <Value>`$adminPassword</Value>",
                "          <PlainText>true</PlainText>",
                "        </Password>",
                "      </AutoLogon>",
                "      <OOBE>",
                "        <HideEULAPage>true</HideEULAPage>",
                "        <HideLocalAccountScreen>true</HideLocalAccountScreen>",
                "        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>",
                "        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>",
                "        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>",
                "        <NetworkLocation>Work</NetworkLocation>",
                "        <ProtectYourPC>1</ProtectYourPC>",
                "        <SkipMachineOOBE>true</SkipMachineOOBE>",
                "        <SkipUserOOBE>true</SkipUserOOBE>",
                "      </OOBE>",
                "    </component>",
                "  </settings>",
                "</unattend>"
            ) -join [Environment]::NewLine
            Set-Content -Path `$unattendPath -Value `$unattendXml -Encoding UTF8 -Force
        }
        finally {
            Dismount-VHD -Path `$guestVhdPath -ErrorAction SilentlyContinue
        }
    }
    finally {
        Dismount-DiskImage -ImagePath `$windowsIsoPath -ErrorAction SilentlyContinue
    }
}

`$existingVm = Get-VM -Name `$vmName -ErrorAction SilentlyContinue
if (`$null -eq `$existingVm) {
    New-Item -ItemType Directory -Path `$guestRootPath -Force | Out-Null
    New-VM -Name `$vmName -Generation 2 -MemoryStartupBytes 4GB -VHDPath `$guestVhdPath -Path `$guestRootPath -SwitchName `$natSwitchName | Out-Null
    Set-VMProcessor -VMName `$vmName -Count 2
    Set-VMMemory -VMName `$vmName -DynamicMemoryEnabled `$false
    Set-VMFirmware -VMName `$vmName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
}
else {
    Set-VMProcessor -VMName `$vmName -Count 2
    Set-VMMemory -VMName `$vmName -StartupBytes 4GB -DynamicMemoryEnabled `$false
}

if ((Get-VM -Name `$vmName).State -ne 'Running') {
    Start-VM -Name `$vmName | Out-Null
}

`$session = `$null
`$sessionDeadline = (Get-Date).AddMinutes(30)
do {
    try {
        `$session = New-PSSession -VMName `$vmName -Credential `$guestCredential -ErrorAction Stop
    }
    catch {
        Start-Sleep -Seconds 20
    }
}
while (`$null -eq `$session -and (Get-Date) -lt `$sessionDeadline)

if (`$null -eq `$session) {
    throw "The nested VM '`$vmName' did not become ready for PowerShell Direct in the expected time."
}

try {
    Invoke-Command -Session `$session -ArgumentList `$sqlMediaUrl, `$sqlLogin, `$sqlPassword, `$natGateway, `$dnsServers, `$nestedIp, `$adminUser -ScriptBlock {
        param(
            [string]`$SqlMediaUrl,
            [string]`$SqlLogin,
            [string]`$SqlPassword,
            [string]`$Gateway,
            [string[]]`$DnsServers,
            [string]`$StaticIp,
            [string]`$AdminUser
        )

        `$ErrorActionPreference = 'Stop'
        `$interface = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
        if (`$null -eq `$interface) {
            throw 'No active network adapter was found in the nested VM.'
        }

        Get-NetIPAddress -InterfaceIndex `$interface.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object IPAddress -ne '127.0.0.1' |
            Remove-NetIPAddress -Confirm:`$false -ErrorAction SilentlyContinue

        New-NetIPAddress -InterfaceIndex `$interface.ifIndex -IPAddress `$StaticIp -PrefixLength 24 -DefaultGateway `$Gateway | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex `$interface.ifIndex -ServerAddresses `$DnsServers

        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' | Out-Null
        if (-not (Get-NetFirewallRule -DisplayName 'Allow SQL Server 1433' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName 'Allow SQL Server 1433' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 | Out-Null
        }

        `$installerRoot = 'C:\Installers'
        New-Item -ItemType Directory -Path `$installerRoot -Force | Out-Null
        if ([string]::IsNullOrWhiteSpace(`$SqlMediaUrl)) {
            `$bootstrapPath = Join-Path `$installerRoot 'SQL2022-SSEI-Dev.exe'
            Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=866658' -OutFile `$bootstrapPath -UseBasicParsing -ErrorAction Stop
            `$downloadRoot = Join-Path `$installerRoot 'SqlMedia'
            New-Item -ItemType Directory -Path `$downloadRoot -Force | Out-Null
            & `$bootstrapPath /ACTION=Download /MEDIATYPE=ISO /MEDIAPATH=`$downloadRoot /QUIET | Out-Null
            `$mediaPath = Get-ChildItem -Path `$downloadRoot -Filter *.iso -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        }
        else {
            `$fileName = Split-Path -Path ([uri]`$SqlMediaUrl).AbsolutePath -Leaf
            if ([string]::IsNullOrWhiteSpace(`$fileName)) {
                `$fileName = 'sql-media.exe'
            }

            `$downloadPath = Join-Path `$installerRoot `$fileName
            Invoke-WebRequest -Uri `$SqlMediaUrl -OutFile `$downloadPath -UseBasicParsing -ErrorAction Stop
            if (`$downloadPath -match '\.iso$') {
                `$mediaPath = `$downloadPath
            }
            else {
                `$downloadRoot = Join-Path `$installerRoot 'SqlMedia'
                New-Item -ItemType Directory -Path `$downloadRoot -Force | Out-Null
                & `$downloadPath /ACTION=Download /MEDIATYPE=ISO /MEDIAPATH=`$downloadRoot /QUIET | Out-Null
                `$mediaPath = Get-ChildItem -Path `$downloadRoot -Filter *.iso -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
            }
        }

        if (-not `$mediaPath) {
            throw 'SQL Server installation media could not be located after download.'
        }

        `$mountedSqlIso = Mount-DiskImage -ImagePath `$mediaPath -PassThru -StorageType ISO -ErrorAction Stop
        try {
            `$sqlVolume = `$mountedSqlIso | Get-Volume
            `$setupPath = "`$(`$sqlVolume.DriveLetter):\setup.exe"
            `$setupArgs = @(
                '/Q',
                '/ACTION=Install',
                '/FEATURES=SQLENGINE',
                '/INSTANCENAME=MSSQLSERVER',
                '/TCPENABLED=1',
                '/SQLSVCACCOUNT="NT AUTHORITY\\SYSTEM"',
                '/AGTSVCSTARTUPTYPE=Automatic',
                '/SQLSYSADMINACCOUNTS="BUILTIN\\Administrators"',
                '/SECURITYMODE=SQL',
                "/SAPWD=`$SqlPassword",
                '/IACCEPTSQLSERVERLICENSETERMS',
                '/UPDATEENABLED=0'
            )

            `$process = Start-Process -FilePath `$setupPath -ArgumentList `$setupArgs -Wait -PassThru -NoNewWindow
            if (`$process.ExitCode -ne 0) {
                throw "SQL Server setup failed with exit code `$(`$process.ExitCode)."
            }
        }
        finally {
            Dismount-DiskImage -ImagePath `$mediaPath -ErrorAction SilentlyContinue
        }

        `$instanceNames = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
        `$instanceName = (`$instanceNames.PSObject.Properties | Select-Object -First 1).Name
        if (-not `$instanceName) {
            throw 'No SQL Server instance was found after setup completed.'
        }

        `$instanceId = `$instanceNames.`$instanceName
        `$loginModePath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\`$instanceId\MSSQLServer"
        Set-ItemProperty -Path `$loginModePath -Name 'LoginMode' -Value 2
        Restart-Service -Name 'MSSQLSERVER' -Force

        `$escapedLogin = `$SqlLogin.Replace(']', ']]')
        `$escapedPassword = `$SqlPassword.Replace("'", "''")
        `$sqlStatement = @(
            "IF SUSER_ID(N'`$escapedLogin') IS NULL",
            'BEGIN',
            "    CREATE LOGIN [`$escapedLogin] WITH PASSWORD = N'`$escapedPassword', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;",
            'END',
            'ELSE',
            'BEGIN',
            "    ALTER LOGIN [`$escapedLogin] WITH PASSWORD = N'`$escapedPassword';",
            'END',
            "IF IS_SRVROLEMEMBER('sysadmin', N'`$escapedLogin') <> 1",
            'BEGIN',
            "    ALTER SERVER ROLE [sysadmin] ADD MEMBER [`$escapedLogin];",
            'END'
        ) -join [Environment]::NewLine

        if (Get-Command -Name sqlcmd.exe -ErrorAction SilentlyContinue) {
            & sqlcmd.exe -S localhost -E -Q `$sqlStatement
            if (`$LASTEXITCODE -ne 0) {
                throw 'sqlcmd.exe returned a non-zero exit code while creating the SQL login.'
            }
        }
        else {
            throw 'sqlcmd.exe is not available after SQL Server installation.'
        }

        [pscustomobject]@{
            NestedVmName = `$env:COMPUTERNAME
            IpAddress    = `$StaticIp
            SqlLogin     = `$SqlLogin
            InstanceName = `$instanceName
        }
    } | Out-Null
}
finally {
    if (`$session) {
        Remove-PSSession -Session `$session -ErrorAction SilentlyContinue
    }
}

`$metadata = [pscustomobject]@{
    NestedVmName   = `$vmName
    IpAddress      = `$nestedIp
    SqlPort        = 1433
    SqlLogin       = `$sqlLogin
    CredentialPath = `$stateCredentialPath
    UpdatedUtc     = (Get-Date).ToUniversalTime().ToString('o')
}
`$metadata | ConvertTo-Json | Set-Content -Path `$stateMetadataPath -Encoding UTF8 -Force
`$metadata | ConvertTo-Json -Compress
"@

    if ($PSCmdlet.ShouldProcess($HostVmName, "Create nested VM '$NestedVmName' and install SQL Server")) {
        Write-Verbose "Creating nested VM '$NestedVmName' through host '$HostVmName'."
        $runCommandSplat = @{
            ResourceGroupName = $HostResourceGroupName
            VMName            = $HostVmName
            CommandId         = 'RunPowerShellScript'
            ScriptString      = $runCommandScript
            ErrorAction       = 'Stop'
        }
        $null = Invoke-AzVMRunCommand @runCommandSplat
    }

    [pscustomobject]@{
        HostResourceGroupName     = $HostResourceGroupName
        HostVmName                = $HostVmName
        NestedVmName              = $NestedVmName
        NestedVmIpAddress         = '172.16.0.10'
        SqlPort                   = 1433
        SqlInstance               = 'MSSQLSERVER'
        SqlLogin                  = $SqlAuthUsername
        SqlConnectionString       = "Server=tcp:172.16.0.10,1433;Initial Catalog=master;Persist Security Info=False;User ID=$SqlAuthUsername;Password=<password>;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
        HostCredentialStatePath   = "C:\NestedSqlLab\State\$NestedVmName-admin.xml"
        HostMetadataStatePath     = "C:\NestedSqlLab\State\$NestedVmName.json"
    }
}
catch {
    Write-Error "Failed to deploy nested SQL VM: $($_.Exception.Message)"
    throw
}
