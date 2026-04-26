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

function Get-BlockedInheritanceData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    Get-ADOrganizationalUnit -Filter * -Properties gPOptions @CommonParams |
        Where-Object { ($_.gPOptions -band 1) -eq 1 } |
        ForEach-Object {
            [PSCustomObject]@{
                Name              = $_.Name
                DistinguishedName = $_.DistinguishedName
            }
        }
}

Export-ModuleMember -Function Get-OUsData, Get-BlockedInheritanceData
