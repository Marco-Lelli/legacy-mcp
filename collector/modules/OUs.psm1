# OUs.psm1 — Organizational Unit data collection helpers

function Get-OUsData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    Get-ADOrganizationalUnit -Filter * -Properties gpLink, gPOptions @CommonParams |
        ForEach-Object {
            [PSCustomObject]@{
                Name               = $_.Name
                DistinguishedName  = $_.DistinguishedName
                BlockedInheritance = ($_.gPOptions -band 1) -eq 1
                LinkedGPOs         = $_.gpLink
            }
        }
}

Export-ModuleMember -Function Get-OUsData
