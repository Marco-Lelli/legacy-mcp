# GPO.psm1 — GPO inventory data collection helpers
# Requires: GroupPolicy PowerShell module (RSAT)

function Get-GPOData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    try {
        Get-GPO -All @CommonParams | ForEach-Object {
            [PSCustomObject]@{
                DisplayName      = $_.DisplayName
                Id               = $_.Id.ToString()
                GpoStatus        = $_.GpoStatus.ToString()
                CreationTime     = $_.CreationTime
                ModificationTime = $_.ModificationTime
                Owner            = $_.Owner
            }
        }
    } catch {
        Write-Warning "GPO cmdlets not available. Install RSAT GroupPolicy tools."
        @()
    }
}

function Get-GPOLinksData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    # Iterate domain root and every OU to capture all direct GPO links.
    # Get-GPInheritance.GpoLinks returns only direct links on each target,
    # so a GPO linked to multiple OUs appears as multiple rows.
    try {
        $domainDN = (Get-ADDomain @CommonParams).DistinguishedName
        $ouDNs    = Get-ADOrganizationalUnit -Filter * @CommonParams |
                        Select-Object -ExpandProperty DistinguishedName
        $targets  = @($domainDN) + @($ouDNs)
        $targets | ForEach-Object {
            $target = $_
            try {
                Get-GPInheritance -Target $target @CommonParams |
                    Select-Object -ExpandProperty GpoLinks |
                    ForEach-Object {
                        [PSCustomObject]@{
                            DisplayName = $_.DisplayName
                            GpoId       = $_.GpoId.ToString()
                            Enabled     = $_.Enabled
                            Enforced    = $_.Enforced
                            Target      = $_.Target
                            Order       = $_.Order
                        }
                    }
            } catch { }
        }
    } catch { @() }
}

Export-ModuleMember -Function Get-GPOData, Get-GPOLinksData
