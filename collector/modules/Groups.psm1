# Groups.psm1 — AD Group data collection helpers

$PrivilegedGroupNames = @(
    "Domain Admins", "Enterprise Admins", "Schema Admins",
    "Administrators", "Account Operators", "Backup Operators",
    "Print Operators", "Server Operators"
)

function Get-GroupsData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    # Get-ADGroupMember handles range retrieval for large groups (>1500 members).
    # $_.Members.Count truncates at the LDAP page boundary -- not used here.
    # -1 signals a retrieval failure, not an empty group.
    Get-ADGroup -Filter * -Properties adminCount @CommonParams | ForEach-Object {
        $count = try {
            (Get-ADGroupMember -Identity $_.DistinguishedName @CommonParams |
                Measure-Object).Count
        } catch { -1 }
        [PSCustomObject]@{
            Name              = $_.Name
            SamAccountName    = $_.SamAccountName
            DistinguishedName = $_.DistinguishedName
            GroupCategory     = $_.GroupCategory.ToString()
            GroupScope        = $_.GroupScope.ToString()
            MemberCount       = $count
            AdminCount        = $_.adminCount
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
