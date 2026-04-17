# DomainControllers.psm1 — DC data collection helpers

function Get-DCData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    Get-ADDomainController -Filter * @CommonParams | ForEach-Object {
        $dc = $_

        # Server Core detection via registry -- Remote Management Users sufficient
        $isServerCore = $null
        try {
            $installType = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" `
                    -ErrorAction SilentlyContinue).InstallationType
            } -ErrorAction SilentlyContinue
            $isServerCore = ($installType -eq "Server Core")
        } catch {
            $isServerCore = $null
        }

        [PSCustomObject]@{
            Name                   = $dc.Name
            HostName               = $dc.HostName
            IPv4Address            = $dc.IPv4Address
            Site                   = $dc.Site
            OperatingSystem        = $dc.OperatingSystem
            OperatingSystemVersion = $dc.OperatingSystemVersion
            IsGlobalCatalog        = $dc.IsGlobalCatalog
            IsReadOnly             = $dc.IsReadOnly
            Enabled                = $dc.Enabled
            DistinguishedName      = $dc.ComputerObjectDN
            Reachable              = (Test-Connection $dc.HostName -Count 1 -Quiet)
            # New fields -- Webster gap closure
            LdapPort               = 389
            SslPort                = 636
            OperationMasterRoles   = ($dc.OperationMasterRoles -join ", ")
            IsServerCore           = $isServerCore
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
                $timeSource = $null
                try {
                    $ts = (w32tm /query /source 2>&1) -join ""
                    if ($ts -notmatch "(?i)error|denied|0x8") { $timeSource = $ts.Trim() }
                } catch { $timeSource = $null }
                [PSCustomObject]@{
                    NtpServer               = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters" -ErrorAction SilentlyContinue).NtpServer
                    Type                    = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters" -ErrorAction SilentlyContinue).Type
                    AnnounceFlags           = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config" -ErrorAction SilentlyContinue).AnnounceFlags
                    MaxNegPhaseCorrection   = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config" -ErrorAction SilentlyContinue).MaxNegPhaseCorrection
                    MaxPosPhaseCorrection   = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config" -ErrorAction SilentlyContinue).MaxPosPhaseCorrection
                    SpecialPollInterval     = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config" -ErrorAction SilentlyContinue).SpecialPollInterval
                    NtpClientPollInterval   = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient" -ErrorAction SilentlyContinue).SpecialPollInterval
                    VMICTimeProviderEnabled = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\VMICTimeProvider" -ErrorAction SilentlyContinue).Enabled
                    TimeSource              = $timeSource
                }
            } -ErrorAction Stop |
                Select-Object -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName

            $successCount++
            [PSCustomObject]@{
                DC                      = $dc.HostName
                NtpServer               = $regData.NtpServer
                Type                    = $regData.Type
                AnnounceFlags           = $regData.AnnounceFlags
                MaxNegPhaseCorrection   = $regData.MaxNegPhaseCorrection
                MaxPosPhaseCorrection   = $regData.MaxPosPhaseCorrection
                SpecialPollInterval     = $regData.SpecialPollInterval
                NtpClientPollInterval   = $regData.NtpClientPollInterval
                VMICTimeProviderEnabled = $regData.VMICTimeProviderEnabled
                TimeSource              = $regData.TimeSource
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
                NtpClientPollInterval   = $null
                VMICTimeProviderEnabled = $null
                TimeSource              = $null
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
            # Explicit list: Get-WinEvent -ListLog * requires elevated privileges with POLP.
            # Application and System: certified with Event Log Readers (T20).
            # DC-specific logs: per-log try/catch -- absent or inaccessible logs skipped silently.
            $dcLogs = @("Application", "System", "Directory Service",
                        "DNS Server", "File Replication Service", "DFS Replication")
            $logs = foreach ($logName in $dcLogs) {
                try {
                    Get-WinEvent -ListLog $logName -ComputerName $dc.HostName -ErrorAction Stop
                } catch {
                    # Log not present or not accessible on this DC -- skip silently
                }
            }
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
    # Derive DomainDN once for LDAP queries
    $domainDN = (Get-ADDomain @CommonParams).DistinguishedName
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
                # No DFSR replicated folders found.
                # Step 2a: check AD for DFSR-GlobalSettings via LDAP (no extra permissions needed)
                # Wrapped in try/catch: SearchRoot assignment can throw DirectoryServicesCOMException
                # if the DN does not exist (FRS environment).
                try {
                    $dfsrGlobalDN = "CN=DFSR-GlobalSettings,CN=System,$domainDN"
                    $searcher = New-Object DirectoryServices.DirectorySearcher
                    $searcher.SearchRoot = New-Object DirectoryServices.DirectoryEntry(
                        "LDAP://$dcName/$dfsrGlobalDN")
                    $searcher.SearchScope = "Base"
                    $dfsrGlobal = $searcher.FindOne()
                } catch [System.Runtime.InteropServices.COMException] {
                    # CN=DFSR-GlobalSettings does not exist -> FRS environment
                    $dfsrGlobal = $null
                } catch {
                    # Any other LDAP error -> treat as FRS, log error
                    $dfsrGlobal = $null
                }

                if ($dfsrGlobal) {
                    # DFSR-GlobalSettings exists but no replicated folders on this DC yet
                    $successCount++
                    [PSCustomObject]@{
                        DC        = $dcName
                        Mechanism = "DFSR"
                        State     = "Not Configured"
                        Status    = "OK"
                    }
                } else {
                    # DFSR-GlobalSettings absent -- FRS environment.
                    # Step 2b: confirm NtFrs service via Invoke-Command registry read
                    # (Remote Management Users already granted -- no extra permissions)
                    $ntfrs = Invoke-Command -ComputerName $dcName -ScriptBlock {
                        $svc = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NtFrs" `
                            -ErrorAction SilentlyContinue
                        [PSCustomObject]@{
                            ServiceFound = [bool]$svc
                            Start        = if ($svc) { $svc.Start } else { $null }
                        }
                    } -ErrorAction SilentlyContinue |
                        Select-Object -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName

                    $successCount++
                    if ($ntfrs -and $ntfrs.ServiceFound) {
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
            # -ErrorVariable cimError captures access denied errors that PS 5.1 does not
            # propagate as catchable exceptions from remote CimInstance calls.
            $cimOpt     = New-CimSessionOption -Protocol WSMan
            $cimSession = New-CimSession -ComputerName $dc.HostName -SessionOption $cimOpt -ErrorAction Stop
            $cimError   = $null
            try {
                $services = Get-CimInstance -CimSession $cimSession -ClassName Win32_Service `
                    -ErrorAction Stop -ErrorVariable cimError |
                    Where-Object { $_.State -eq 'Running' -or $_.StartMode -eq 'Auto' } |
                    Select-Object @{N='name';         E={$_.Name}},
                                  @{N='display_name'; E={$_.DisplayName}},
                                  @{N='status';       E={$_.State}},
                                  @{N='start_type';   E={$_.StartMode}}
            } finally {
                Remove-CimSession $cimSession
            }

            if ($cimError) {
                $errMsg = $cimError[0].Exception.Message
                $statusValue = if ($errMsg -match "(?i)access.denied|0x80070005|0x80338104") {
                    "PermissionDenied"
                } else {
                    "Unreachable"
                }
                $failCount++
                [PSCustomObject]@{
                    DC       = $dc.HostName
                    Status   = $statusValue
                    Services = @()
                }
            } else {
                $successCount++
                [PSCustomObject]@{
                    DC       = $dc.HostName
                    Status   = "OK"
                    Services = @($services)
                }
            }
        } catch {
            $failCount++
            $statusValue = if ($_.Exception.Message -match "(?i)access.denied|0x80070005|0x80338104") {
                "PermissionDenied"
            } else {
                "Unreachable"
            }
            [PSCustomObject]@{
                DC       = $dc.HostName
                Status   = $statusValue
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

function Get-DCFileLocationsData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $dcs = Get-ADDomainController -Filter * @CommonParams
    Write-Host "DC Inventory: found $($dcs.Count) Domain Controller(s)."
    $successCount = 0
    $failCount = 0
    foreach ($dc in $dcs) {
        try {
            $regData = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                # Read AD file locations from registry via Invoke-Command.
                # Remote Management Users sufficient -- no Administrators required.
                # DIT file size NOT collected: requires filesystem access to %windir%\NTDS
                # which is blocked without local Administrators (POLP limitation, by design).
                $ntdsParams = Get-ItemProperty `
                    "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" `
                    -ErrorAction SilentlyContinue
                $netlogon = Get-ItemProperty `
                    "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters" `
                    -ErrorAction SilentlyContinue
                [PSCustomObject]@{
                    DatabasePath = $ntdsParams."DSA Working Directory"
                    LogPath      = $ntdsParams."Database log files path"
                    SysvolPath   = $netlogon.SysVol
                }
            } -ErrorAction Stop |
                Select-Object -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName

            $successCount++
            [PSCustomObject]@{
                DC           = $dc.HostName
                DatabasePath = $regData.DatabasePath
                LogPath      = $regData.LogPath
                SysvolPath   = $regData.SysvolPath
                Status       = "OK"
            }
        } catch {
            $failCount++
            [PSCustomObject]@{
                DC           = $dc.HostName
                DatabasePath = $null
                LogPath      = $null
                SysvolPath   = $null
                Status       = "Unreachable"
            }
        }
    }
    Write-Host "DC Inventory: collected $successCount, failed $failCount."
}

Export-ModuleMember -Function Get-DCData, Get-NtpConfigData, Get-EventLogConfigData, Get-SysvolData, Get-DCWindowsFeaturesData, Get-DCServicesData, Get-DCInstalledSoftwareData, Get-DCFileLocationsData
