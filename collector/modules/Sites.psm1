# Sites.psm1 — AD Sites and site links data collection helpers

function Get-SitesData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    Get-ADReplicationSite -Filter * @CommonParams | ForEach-Object {
        $siteDN = $_.DistinguishedName
        $subnets = try {
            (Get-ADReplicationSubnet -Filter "Site -eq '$siteDN'" @CommonParams).Name -join ", "
        } catch { "" }

        [PSCustomObject]@{
            Name        = $_.Name
            Description = $_.Description
            Subnets     = $subnets
        }
    }
}

function Get-SiteLinksData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    Get-ADReplicationSiteLink -Filter * @CommonParams | ForEach-Object {
        [PSCustomObject]@{
            Name                        = $_.Name
            Cost                        = $_.Cost
            ReplicationFrequencyMinutes = $_.ReplicationFrequencyInMinutes
            Transport                   = $_.InterSiteTransportProtocol
            SitesIncluded               = $_.SitesIncluded -join ", "
        }
    }
}

Export-ModuleMember -Function Get-SitesData, Get-SiteLinksData
