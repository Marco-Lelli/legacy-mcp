# Trusts.psm1 — Trust relationship data collection helpers

function Get-TrustsData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    Get-ADTrust -Filter * @CommonParams | ForEach-Object {
        [PSCustomObject]@{
            Name                     = $_.Name
            Direction                = $_.Direction.ToString()
            TrustType                = $_.TrustType.ToString()
            TrustAttributes          = $_.TrustAttributes
            SelectiveAuthentication  = $_.SelectiveAuthentication
            SIDFilteringForestAware  = $_.SIDFilteringForestAware
            SIDFilteringQuarantined  = $_.SIDFilteringQuarantined
            DisallowTransivity       = $_.DisallowTransivity
            DistinguishedName        = $_.DistinguishedName
        }
    }
}

Export-ModuleMember -Function Get-TrustsData
