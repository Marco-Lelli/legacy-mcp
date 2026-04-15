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
    Write-Host "DC Inventory: found $($dcs.Count) Domain Controller(s)."
    $successCount = 0
    $failCount = 0
    foreach ($dc in $dcs) {
        try {
            $reg    = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey("LocalMachine", $dc.HostName)
            $params = $reg.OpenSubKey("SYSTEM\CurrentControlSet\Services\W32Time\Parameters")
            $config = $reg.OpenSubKey("SYSTEM\CurrentControlSet\Services\W32Time\Config")
            $vmic   = $reg.OpenSubKey("SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\VMICTimeProvider")

            $successCount++
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
            $failCount++
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
    Write-Host "DC Inventory: collected $successCount, failed $failCount."
}

function Get-EventLogConfigData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $dcs = Get-ADDomainController -Filter * @CommonParams
    Write-Host "DC Inventory: found $($dcs.Count) Domain Controller(s)."
    $successCount = 0
    $failCount = 0
    foreach ($dc in $dcs) {
        try {
            $logs = Get-WinEvent -ListLog "Application", "System", "Security" `
                -ComputerName $dc.HostName -ErrorAction Stop
            $successCount++
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
            $failCount++
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
    Write-Host "DC Inventory: collected $successCount, failed $failCount."
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

    $dcs = Get-ADDomainController -Filter * @CommonParams
    Write-Host "DC Inventory: found $($dcs.Count) Domain Controller(s)."
    $successCount = 0
    $failCount = 0
    foreach ($dc in $dcs) {
        $dcName = $dc.HostName
        try {
            $dfsr = Get-WmiObject -Namespace "root\MicrosoftDFS" `
                -Class DfsrReplicatedFolderInfo `
                -ComputerName $dcName `
                -Filter "ReplicatedFolderName='SYSVOL Share'" `
                -ErrorAction Stop
            $successCount++
            [PSCustomObject]@{
                DC        = $dcName
                Mechanism = "DFSR"
                State     = if ($dfsr) { $SysvolStateMap[[int]$dfsr.State] ?? $dfsr.State } else { "Not Found" }
                Status    = "OK"
            }
        } catch {
            $failCount++
            [PSCustomObject]@{
                DC        = $dcName
                Mechanism = "Unknown"
                State     = "Unreachable"
                Status    = "Unreachable"
            }
        }
    }
    Write-Host "DC Inventory: collected $successCount, failed $failCount."
}

function Get-DCWindowsFeaturesData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $dcs = Get-ADDomainController -Filter * @CommonParams
    Write-Host "DC Inventory: found $($dcs.Count) Domain Controller(s)."
    $successCount = 0
    $failCount = 0
    foreach ($dc in $dcs) {
        try {
            $features = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                Import-Module ServerManager -ErrorAction SilentlyContinue
                Get-WindowsFeature |
                    Where-Object { $_.InstallState -eq 'Installed' -and $_.FeatureType -eq 'Role' } |
                    Select-Object @{N='name'; E={$_.Name}},
                                  @{N='display_name'; E={$_.DisplayName}}
            } -ErrorAction Stop

            $successCount++
            [PSCustomObject]@{
                DC       = $dc.HostName
                Status   = "OK"
                Features = @($features)
            }
        } catch {
            $failCount++
            [PSCustomObject]@{
                DC       = $dc.HostName
                Status   = "Unreachable"
                Features = @()
            }
        }
    }
    Write-Host "DC Inventory: collected $successCount, failed $failCount."
}

function Get-DCServicesData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $dcs = Get-ADDomainController -Filter * @CommonParams
    Write-Host "DC Inventory: found $($dcs.Count) Domain Controller(s)."
    $successCount = 0
    $failCount = 0
    foreach ($dc in $dcs) {
        try {
            $services = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                Get-Service |
                    Where-Object { $_.Status -eq 'Running' -or $_.StartType -eq 'Automatic' } |
                    Select-Object @{N='name';         E={$_.ServiceName}},
                                  @{N='display_name'; E={$_.DisplayName}},
                                  @{N='status';       E={$_.Status.ToString()}},
                                  @{N='start_type';   E={$_.StartType.ToString()}}
            } -ErrorAction Stop

            $successCount++
            [PSCustomObject]@{
                DC       = $dc.HostName
                Status   = "OK"
                Services = @($services)
            }
        } catch {
            $failCount++
            [PSCustomObject]@{
                DC       = $dc.HostName
                Status   = "Unreachable"
                Services = @()
            }
        }
    }
    Write-Host "DC Inventory: collected $successCount, failed $failCount."
}

function Get-DCInstalledSoftwareData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $dcs = Get-ADDomainController -Filter * @CommonParams
    Write-Host "DC Inventory: found $($dcs.Count) Domain Controller(s)."
    $successCount = 0
    $failCount = 0
    foreach ($dc in $dcs) {
        try {
            $software = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                $paths = @(
                    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
                )
                foreach ($path in $paths) {
                    Get-ItemProperty $path -ErrorAction SilentlyContinue |
                        Where-Object { $_.DisplayName } |
                        Select-Object @{N='name';         E={$_.DisplayName}},
                                      @{N='version';      E={$_.DisplayVersion}},
                                      @{N='vendor';       E={$_.Publisher}},
                                      @{N='install_date'; E={$_.InstallDate}},
                                      @{N='_source';      E={'registry'}},
                                      @{N='_note';        E={'data may include stale entries from incomplete uninstalls'}}
                }
            } -ErrorAction Stop

            $successCount++
            [PSCustomObject]@{
                DC       = $dc.HostName
                Status   = "OK"
                Software = @($software | Sort-Object name -Unique)
            }
        } catch {
            $failCount++
            [PSCustomObject]@{
                DC       = $dc.HostName
                Status   = "Unreachable"
                Software = @()
            }
        }
    }
    Write-Host "DC Inventory: collected $successCount, failed $failCount."
}

Export-ModuleMember -Function Get-DCData, Get-NtpConfigData, Get-EventLogConfigData, Get-SysvolData, Get-DCWindowsFeaturesData, Get-DCServicesData, Get-DCInstalledSoftwareData
