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

function Get-GroupMembersData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    # One row per direct member per group. Enabled is resolved for user and
    # computer objects only -- null for groups, contacts, and other types.
    # Groups with no members produce no rows. Nested membership is not expanded
    # here; use Get-PrivilegedGroupsData for recursive expansion of sensitive groups.
    Get-ADGroup -Filter * @CommonParams | ForEach-Object {
        $groupName = $_.Name
        $groupDN   = $_.DistinguishedName
        try {
            Get-ADGroupMember -Identity $groupDN @CommonParams | ForEach-Object {
                $member  = $_
                $enabled = $null
                if ($member.objectClass -eq "user") {
                    try {
                        $enabled = (Get-ADUser -Identity $member.distinguishedName `
                            -Properties Enabled @CommonParams).Enabled
                    } catch { }
                } elseif ($member.objectClass -eq "computer") {
                    try {
                        $enabled = (Get-ADComputer -Identity $member.distinguishedName `
                            -Properties Enabled @CommonParams).Enabled
                    } catch { }
                }
                [PSCustomObject]@{
                    GroupName               = $groupName
                    MemberSamAccountName    = $member.SamAccountName
                    MemberDisplayName       = $member.name
                    MemberObjectClass       = $member.objectClass
                    MemberDistinguishedName = $member.distinguishedName
                    MemberEnabled           = $enabled
                }
            }
        } catch { }
    }
}

Export-ModuleMember -Function Get-GroupsData, Get-PrivilegedGroupsData, Get-GroupMembersData
