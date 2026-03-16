# Computers.psm1 — AD Computer object data collection helpers
#
# CNO (Cluster Name Object) detection: computer objects with
# "MSClusterVirtualServer" in their ServicePrincipalNames.
# VCO (Virtual Computer Object) detection: computer objects created by
# cluster roles — distinguished from CNOs by lacking MSClusterVirtualServer
# but having MSClusterVirtualServer in a parent CNO's SPN; here we flag them
# as VCO when isCriticalSystemObject is set and they are not a CNO.

function Get-ComputersData {
    [CmdletBinding()]
    param(
        [hashtable]$CommonParams = @{},
        [int]$Limit = 10000
    )

    Get-ADComputer -Filter * -Properties OperatingSystem, OperatingSystemVersion,
        Enabled, LastLogonDate, PasswordLastSet, Description,
        ServicePrincipalNames, isCriticalSystemObject @CommonParams |
        Select-Object -First $Limit |
        ForEach-Object {
            $isCNO = $_.ServicePrincipalNames -like "*MSClusterVirtualServer*"
            $isVCO = (-not $isCNO) -and $_.isCriticalSystemObject

            [PSCustomObject]@{
                Name                   = $_.Name
                DistinguishedName      = $_.DistinguishedName
                OperatingSystem        = $_.OperatingSystem
                OperatingSystemVersion = $_.OperatingSystemVersion
                Enabled                = $_.Enabled
                LastLogonDate          = $_.LastLogonDate
                PasswordLastSet        = $_.PasswordLastSet
                Description            = $_.Description
                IsCNO                  = [bool]$isCNO
                IsVCO                  = [bool]$isVCO
            }
        }
}

Export-ModuleMember -Function Get-ComputersData
