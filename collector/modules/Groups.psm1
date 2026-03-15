# Groups.psm1 — AD Group data collection helpers

$PrivilegedGroupNames = @(
    "Domain Admins", "Enterprise Admins", "Schema Admins",
    "Administrators", "Account Operators", "Backup Operators",
    "Print Operators", "Server Operators"
)

function Get-GroupsData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    Get-ADGroup -Filter * -Properties Members @CommonParams | ForEach-Object {
        [PSCustomObject]@{
            Name           = $_.Name
            SamAccountName = $_.SamAccountName
            GroupCategory  = $_.GroupCategory.ToString()
            GroupScope     = $_.GroupScope.ToString()
            MemberCount    = $_.Members.Count
        }
    }
}

function Get-PrivilegedGroupsData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    foreach ($groupName in $PrivilegedGroupNames) {
        try {
            $members = Get-ADGroupMember -Identity $groupName -Recursive @CommonParams |
                Select-Object SamAccountName, objectClass, distinguishedName
            [PSCustomObject]@{
                Group   = $groupName
                Members = @($members)
            }
        } catch {
            [PSCustomObject]@{
                Group   = $groupName
                Members = @()
                Error   = $_.ToString()
            }
        }
    }
}

Export-ModuleMember -Function Get-GroupsData, Get-PrivilegedGroupsData
