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
            $regData = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                # Read NTP config via Invoke-Command: OpenRemoteBaseKey is not delegable
                # on WS2012R2 without local Administrators. Remote Management Users is sufficient.
                [PSCustomObject]@{
                    NtpServer               = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters" -ErrorAction SilentlyContinue).NtpServer
                    Type                    = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters" -ErrorAction SilentlyContinue).Type
                    AnnounceFlags           = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config" -ErrorAction SilentlyContinue).AnnounceFlags
                    MaxNegPhaseCorrection   = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config" -ErrorAction SilentlyContinue).MaxNegPhaseCorrection
                    MaxPosPhaseCorrection   = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config" -ErrorAction SilentlyContinue).MaxPosPhaseCorrection
                    SpecialPollInterval     = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config" -ErrorAction SilentlyContinue).SpecialPollInterval
                    VMICTimeProviderEnabled = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\VMICTimeProvider" -ErrorAction SilentlyContinue).Enabled
                }
            } -ErrorAction Stop |
                Select-Object -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName # Strip PowerShell remoting artifacts -- not part of LegacyMCP data model

            $successCount++
            [PSCustomObject]@{
                DC                      = $dc.HostName
                NtpServer               = $regData.NtpServer
                Type                    = $regData.Type
                AnnounceFlags           = $regData.AnnounceFlags
                MaxNegPhaseCorrection   = $regData.MaxNegPhaseCorrection
                MaxPosPhaseCorrection   = $regData.MaxPosPhaseCorrection
                SpecialPollInterval     = $regData.SpecialPollInterval
                VMICTimeProviderEnabled = $regData.VMICTimeProviderEnabled
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
            # "Security" log removed: its ACL is not delegable without local Administrators.
            # Application and System are sufficient for EventLog configuration assessment.
            $logs = Get-WinEvent -ListLog "Application", "System" `
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
            $dfsr = @(Get-WmiObject -Namespace "root\MicrosoftDFS" `
                -Class DfsrReplicatedFolderInfo `
                -ComputerName $dcName `
                -Filter "ReplicatedFolderName='SYSVOL Share'" `
                -ErrorAction Stop)

            if ($dfsr.Count -gt 0) {
                # DFSR is active -- read state from map
                $stateInt = [int]$dfsr[0].State
                $stateStr = if ($SysvolStateMap.ContainsKey($stateInt)) {
                    $SysvolStateMap[$stateInt]
                } else {
                    "Unknown ($stateInt)"
                }
                $successCount++
                [PSCustomObject]@{
                    DC        = $dcName
                    Mechanism = "DFSR"
                    State     = $stateStr
                    Status    = "OK"
                }
            } else {
                # No DFSR replicated folders found -- check if NTFRS is present
                # CimSession with WSMan: same channel as Remote Management Users.
                $cimOpt     = New-CimSessionOption -Protocol WSMan
                $cimSession = New-CimSession -ComputerName $dcName -SessionOption $cimOpt -ErrorAction Stop
                try {
                    $ntfrs = Get-CimInstance -CimSession $cimSession -ClassName Win32_Service `
                        -Filter "Name='NTFRS'" -ErrorAction SilentlyContinue
                } finally {
                    Remove-CimSession $cimSession
                }

                $successCount++
                if ($ntfrs) {
                    # FRS detected -- state not measurable without unreliable proxy
                    [PSCustomObject]@{
                        DC        = $dcName
                        Mechanism = "FRS"
                        State     = $null
                        Status    = "OK"
                    }
                } else {
                    [PSCustomObject]@{
                        DC        = $dcName
                        Mechanism = "Unknown"
                        State     = $null
                        Status    = "OK"
                    }
                }
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
            } -ErrorAction Stop |
                Select-Object -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName # Strip PowerShell remoting artifacts -- not part of LegacyMCP data model

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
            # CimSession with WSMan protocol: forces Get-CimInstance to use the WinRM channel
            # already authorized for Remote Management Users. DCOM is not used.
            $cimOpt     = New-CimSessionOption -Protocol WSMan
            $cimSession = New-CimSession -ComputerName $dc.HostName -SessionOption $cimOpt -ErrorAction Stop
            try {
                $services = Get-CimInstance -CimSession $cimSession -ClassName Win32_Service |
                    Where-Object { $_.State -eq 'Running' -or $_.StartMode -eq 'Auto' } |
                    Select-Object @{N='name';         E={$_.Name}},
                                  @{N='display_name'; E={$_.DisplayName}},
                                  @{N='status';       E={$_.State}},
                                  @{N='start_type';   E={$_.StartMode}}
            } finally {
                Remove-CimSession $cimSession
            }

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
            } -ErrorAction Stop |
                Select-Object -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName # Strip PowerShell remoting artifacts -- not part of LegacyMCP data model

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
