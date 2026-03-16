# DomainControllers.psm1 — DC data collection helpers

function Get-DCData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    Get-ADDomainController -Filter * @CommonParams | ForEach-Object {
        [PSCustomObject]@{
            Name                   = $_.Name
            HostName               = $_.HostName
            IPv4Address            = $_.IPv4Address
            Site                   = $_.Site
            OperatingSystem        = $_.OperatingSystem
            OperatingSystemVersion = $_.OperatingSystemVersion
            IsGlobalCatalog        = $_.IsGlobalCatalog
            IsReadOnly             = $_.IsReadOnly
            Enabled                = $_.Enabled
            DistinguishedName      = $_.ComputerObjectDN
            Reachable              = (Test-Connection $_.HostName -Count 1 -Quiet)
        }
    }
}

function Get-NtpConfigData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $dcs = Get-ADDomainController -Filter * @CommonParams
    foreach ($dc in $dcs) {
        try {
            $reg    = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey("LocalMachine", $dc.HostName)
            $params = $reg.OpenSubKey("SYSTEM\CurrentControlSet\Services\W32Time\Parameters")
            $config = $reg.OpenSubKey("SYSTEM\CurrentControlSet\Services\W32Time\Config")
            $vmic   = $reg.OpenSubKey("SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\VMICTimeProvider")

            [PSCustomObject]@{
                DC                      = $dc.HostName
                NtpServer               = $params.GetValue("NtpServer")
                Type                    = $params.GetValue("Type")
                AnnounceFlags           = $config.GetValue("AnnounceFlags")
                MaxNegPhaseCorrection   = $config.GetValue("MaxNegPhaseCorrection")
                MaxPosPhaseCorrection   = $config.GetValue("MaxPosPhaseCorrection")
                SpecialPollInterval     = $config.GetValue("SpecialPollInterval")
                VMICTimeProviderEnabled = if ($vmic) { $vmic.GetValue("Enabled") } else { $null }
                Status                  = "OK"
            }
        } catch {
            [PSCustomObject]@{
                DC                      = $dc.HostName
                NtpServer               = $null
                Type                    = $null
                AnnounceFlags           = $null
                MaxNegPhaseCorrection   = $null
                MaxPosPhaseCorrection   = $null
                SpecialPollInterval     = $null
                VMICTimeProviderEnabled = $null
                Status                  = "Unreachable"
            }
        }
    }
}

function Get-EventLogConfigData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $dcs = Get-ADDomainController -Filter * @CommonParams
    foreach ($dc in $dcs) {
        try {
            $logs = Get-WinEvent -ListLog "Application", "System", "Security" `
                -ComputerName $dc.HostName -ErrorAction Stop
            foreach ($log in $logs) {
                [PSCustomObject]@{
                    DC             = $dc.HostName
                    LogName        = $log.LogName
                    MaxSizeBytes   = $log.MaximumSizeInBytes
                    RetentionDays  = $log.LogRetentionDays
                    OverflowAction = $log.LogMode
                    Status         = "OK"
                }
            }
        } catch {
            [PSCustomObject]@{
                DC             = $dc.HostName
                LogName        = $null
                MaxSizeBytes   = $null
                RetentionDays  = $null
                OverflowAction = $null
                Status         = "Unreachable"
            }
        }
    }
}

$SysvolStateMap = @{
    0 = "Uninitialized"
    1 = "Initialized"
    2 = "Initial Sync"
    3 = "Auto Recovery"
    4 = "Normal"
    5 = "In Error"
}

function Get-SysvolData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    Get-ADDomainController -Filter * @CommonParams | ForEach-Object {
        $dcName = $_.HostName
        try {
            $dfsr = Get-WmiObject -Namespace "root\MicrosoftDFS" `
                -Class DfsrReplicatedFolderInfo `
                -ComputerName $dcName `
                -Filter "ReplicatedFolderName='SYSVOL Share'" `
                -ErrorAction Stop
            [PSCustomObject]@{
                DC        = $dcName
                Mechanism = "DFSR"
                State     = if ($dfsr) { $SysvolStateMap[[int]$dfsr.State] ?? $dfsr.State } else { "Not Found" }
                Status    = "OK"
            }
        } catch {
            [PSCustomObject]@{
                DC        = $dcName
                Mechanism = "Unknown"
                State     = "Unreachable"
                Status    = "Unreachable"
            }
        }
    }
}

Export-ModuleMember -Function Get-DCData, Get-NtpConfigData, Get-EventLogConfigData, Get-SysvolData
