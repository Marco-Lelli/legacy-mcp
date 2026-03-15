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
            $reg = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey("LocalMachine", $dc.HostName)
            $key = $reg.OpenSubKey("SYSTEM\CurrentControlSet\Services\W32Time\Parameters")
            [PSCustomObject]@{
                DC        = $dc.HostName
                NtpServer = $key.GetValue("NtpServer")
                Type      = $key.GetValue("Type")
                Status    = "OK"
            }
        } catch {
            [PSCustomObject]@{
                DC        = $dc.HostName
                NtpServer = $null
                Type      = $null
                Status    = "Unreachable"
            }
        }
    }
}

Export-ModuleMember -Function Get-DCData, Get-NtpConfigData
