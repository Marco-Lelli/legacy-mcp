# Groups.psm1 -- AD Group data collection helpers

# Explicit dependency: this module calls Write-SafeCollectorLog. Importing it
# here makes the module self-sufficient, so a standalone import cannot fail
# later with CommandNotFoundException in the middle of a collection -- the
# exact failure class that cost two whole sections on AUSL Romagna. Failing
# at load time is the right failure mode; failing mid-run is not.
Import-Module (Join-Path $PSScriptRoot "Logging.psm1") -Force
# Membership.psm1 owns the shared membership helpers AND the single collector-side
# copy of the privileged group list (Get-PrivilegedGroupNames).
Import-Module (Join-Path $PSScriptRoot "Membership.psm1") -Force

function Get-GroupsData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    # MemberCount is the length of the raw 'member' attribute (task #134).
    # Get-ADGroupMember was capped by the ADWS MaxGroupOrMemberEntries limit
    # (default 5000) and returned -1 for every group above it; reading 'member'
    # is not subject to that cap and the AD module handles LDAP ranging
    # internally. Counting DNs also counts members that no longer resolve,
    # which is the honest membership size.
    # -1 still signals a retrieval failure, not an empty group.
    # Materialized before the loop, not streamed through it. Piping
    # Get-ADGroup straight into a slow ForEach-Object holds the ADWS
    # enumeration cursor open for the whole run; past MaxEnumContextExpiration
    # (default 30 min) the server drops it with "invalid enumeration context"
    # and the section is lost. Task #134 made these loop bodies heavier, which
    # is what pushed Get-GroupMembersData over that limit on AUSL Romagna.
    $allGroups = @(Get-ADGroup -Filter * -Properties adminCount @CommonParams)

    $allGroups | ForEach-Object {
        $count = try {
            # Assign first, then count. Get-RawGroupMemberDNs returns ",$dns"
            # so the array survives the pipeline intact, which also means
            # @(Get-RawGroupMemberDNs ...) would wrap it one level deeper and
            # always count 1. The returned value is already a real array.
            $memberDNs = Get-RawGroupMemberDNs -GroupDN $_.DistinguishedName -CommonParams $CommonParams
            $memberDNs.Count
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

    # Recursive expansion is done by Get-GroupMembersRecursive instead of
    # Get-ADGroupMember -Recursive (task #134): a single unresolvable member
    # no longer discards the entire group. The Error field now marks a real
    # failure (group missing, connection lost), not one broken member.
    foreach ($groupName in (Get-PrivilegedGroupNames)) {
        try {
            $group = Get-ADGroup -Identity $groupName @CommonParams
            $expansion = Get-GroupMembersRecursive -GroupDN $group.DistinguishedName `
                -CommonParams $CommonParams

            if ($expansion.Unresolved.Count -gt 0) {
                Write-SafeCollectorLog -Level WARN -Section "Privileged Groups" `
                    -Message "Group '$groupName': $($expansion.Unresolved.Count) unresolvable members (orphaned SID / removed object / external principal) -- reported as objectClass='unresolved' placeholders, the other members were collected"
            }

            # Field names deliberately keep the original casing: they are part
            # of the JSON contract consumed by the server side.
            $members = @($expansion.Resolved | ForEach-Object {
                [PSCustomObject]@{
                    SamAccountName    = $_.SamAccountName
                    objectClass       = $_.ObjectClass
                    distinguishedName = $_.DistinguishedName
                }
            })

            # Placeholder for an unresolvable DN: reuses the same three keys,
            # no new field. This remains the only place where the "this broken
            # DN sits inside <privileged group>" membership is visible,
            # because group_members only records direct members.
            $members += @($expansion.Unresolved | ForEach-Object {
                [PSCustomObject]@{
                    SamAccountName    = $null
                    objectClass       = "unresolved"
                    distinguishedName = $_
                }
            })

            [PSCustomObject]@{
                Group   = $groupName
                Members = @($members)
            }
        } catch {
            Write-SafeCollectorLog -Level WARN -Section "Privileged Groups" `
                -Message "Group '$groupName' not collected: $_"
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
    #
    # Task #134: members come from the raw 'member' attribute and are resolved
    # one DN at a time, so an orphaned SID costs that one row instead of the
    # whole group. Counters are aggregated and reported once at the end
    # (P4) rather than one warning per member.
    $unresolvableTotal = 0
    $groupsWithUnresolvable = 0
    $groupsFailed = 0

    # Materialized before the loop: the per-member resolution below is far too
    # slow to run while an ADWS enumeration cursor stays open (see the note in
    # Get-GroupsData). This is what cost the whole section on AUSL Romagna
    # with 2289 groups.
    $allGroups = @(Get-ADGroup -Filter * @CommonParams)

    $allGroups | ForEach-Object {
        $groupName = $_.Name
        $groupDN   = $_.DistinguishedName
        try {
            $unresolvableHere = 0
            foreach ($dn in (Get-RawGroupMemberDNs -GroupDN $groupDN -CommonParams $CommonParams)) {
                $member = Resolve-ADMemberByDN -DN $dn -CommonParams $CommonParams
                if ($null -eq $member) {
                    # Placeholder instead of dropping the row: the raw DN is the
                    # useful datum (identifies the broken reference to clean up
                    # in AD) and it preserves the rows == MemberCount invariant.
                    # Reuses the existing keys: no new field, so no risk with
                    # the SQLite schema derived from the first row.
                    $unresolvableHere++
                    [PSCustomObject]@{
                        GroupName               = $groupName
                        MemberSamAccountName    = $null
                        MemberDisplayName       = $null
                        MemberObjectClass       = "unresolved"
                        MemberDistinguishedName = $dn
                        MemberEnabled           = $null
                    }
                    continue
                }
                [PSCustomObject]@{
                    GroupName               = $groupName
                    MemberSamAccountName    = $member.SamAccountName
                    MemberDisplayName       = $member.Name
                    MemberObjectClass       = $member.ObjectClass
                    MemberDistinguishedName = $member.DistinguishedName
                    MemberEnabled           = $member.Enabled
                }
            }
            if ($unresolvableHere -gt 0) {
                $unresolvableTotal += $unresolvableHere
                $groupsWithUnresolvable++
            }
        } catch {
            # Only a real failure reaches here now (group unreadable, connection
            # lost) -- no longer triggered by a single broken member.
            $groupsFailed++
            Write-SafeCollectorLog -Level WARN -Section "Group Members" `
                -Message "Group '$groupName' not enumerated: $_"
        }
    }

    if ($unresolvableTotal -gt 0) {
        Write-SafeCollectorLog -Level WARN -Section "Group Members" `
            -Message "$unresolvableTotal unresolvable members across $groupsWithUnresolvable groups (orphaned SID / removed object / external principal) -- reported as placeholder rows with MemberObjectClass='unresolved' and the raw DN in MemberDistinguishedName"
    }
    if ($groupsFailed -gt 0) {
        Write-SafeCollectorLog -Level WARN -Section "Group Members" `
            -Message "$groupsFailed groups not enumerated due to a read error -- see the preceding WARN lines"
    }
}

Export-ModuleMember -Function Get-GroupsData, Get-PrivilegedGroupsData, Get-GroupMembersData
