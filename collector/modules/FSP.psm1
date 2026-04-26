# FSP.psm1 — Foreign Security Principals data collection helpers

function Get-FSPData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $domainDN = (Get-ADDomain @CommonParams).DistinguishedName
    $fspDN    = "CN=ForeignSecurityPrincipals,$domainDN"

    try {
        Get-ADObject -SearchBase $fspDN -Filter * `
            -Properties objectSid, description @CommonParams |
            Where-Object { $_.ObjectClass -eq "foreignSecurityPrincipal" } |
            ForEach-Object {
                $sidStr   = $_.objectSid.Value
                $resolved = $null
                try {
                    $sid      = New-Object System.Security.Principal.SecurityIdentifier($sidStr)
                    $resolved = $sid.Translate([System.Security.Principal.NTAccount]).Value
                } catch {
                    $resolved = $null
                }
                [PSCustomObject]@{
                    Name              = $_.Name
                    DistinguishedName = $_.DistinguishedName
                    SID               = $sidStr
                    ResolvedName      = $resolved
                    IsOrphaned        = ($null -eq $resolved)
                    Description       = $_.description
                }
            }
    } catch {
        @()
    }
}

Export-ModuleMember -Function Get-FSPData
