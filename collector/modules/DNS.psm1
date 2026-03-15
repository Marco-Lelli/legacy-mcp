# DNS.psm1 — DNS configuration data collection helpers
# Requires: DnsServer PowerShell module (RSAT)

function Get-DNSZonesData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $dcs = (Get-ADDomainController -Filter * @CommonParams).HostName
    $dc = $dcs | Select-Object -First 1

    try {
        Get-DnsServerZone -ComputerName $dc | ForEach-Object {
            [PSCustomObject]@{
                ZoneName           = $_.ZoneName
                ZoneType           = $_.ZoneType.ToString()
                IsDsIntegrated     = $_.IsDsIntegrated
                ReplicationScope   = $_.ReplicationScope
                IsReverseLookupZone = $_.IsReverseLookupZone
                IsAutoCreated      = $_.IsAutoCreated
                DC                 = $dc
            }
        }
    } catch {
        Write-Warning "DNS cmdlets not available on $dc. Install RSAT DNS tools."
        @()
    }
}

function Get-DNSForwardersData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $dcs = (Get-ADDomainController -Filter * @CommonParams).HostName
    foreach ($dc in $dcs) {
        try {
            $fwd = Get-DnsServerForwarder -ComputerName $dc
            [PSCustomObject]@{
                DC          = $dc
                Forwarders  = ($fwd.IPAddress | ForEach-Object { $_.IPAddressToString }) -join ", "
                UseRootHint = $fwd.UseRootHint
                Status      = "OK"
            }
        } catch {
            [PSCustomObject]@{
                DC          = $dc
                Forwarders  = $null
                UseRootHint = $null
                Status      = "Unreachable"
            }
        }
    }
}

Export-ModuleMember -Function Get-DNSZonesData, Get-DNSForwardersData
