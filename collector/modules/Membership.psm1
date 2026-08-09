# Membership.psm1 -- shared AD group membership resolution helpers (task #134).
#
# Why this module exists
# ----------------------
# Get-ADGroupMember fails for the ENTIRE group when a single member cannot be
# resolved (orphaned SID, tombstoned object, foreign security principal across
# a trust). On a multi-forest consolidation this loses the whole membership
# instead of the one broken member. It is additionally capped by the ADWS
# MaxGroupOrMemberEntries limit (default 5000), which surfaces as
# "The size limit for this request was exceeded".
#
# These helpers read the raw 'member' attribute and resolve each DN
# individually, so one broken member costs one member -- not the whole group
# (P9). Members that cannot be resolved are counted and reported in aggregate
# (P4), never silently dropped.
#
# Ranged retrieval
# ----------------
# No explicit member;range=X-Y handling is needed here, and none is possible
# through the AD cmdlets: ADWS expresses ranges as RangeLow/RangeHigh SOAP
# attributes, not as the LDAP attribute-name suffix (see [MS-ADDM] "Range
# Specifiers for Requests"). The AD module performs the range iteration
# internally. Field-verified on the customer environment (2026-08-06):
# reading 'member' returned 6109 DNs on a group where Get-ADGroupMember failed
# with the size limit error -- past both the 1500 MaxValRange boundary and the
# 5000 ADWS cap.
#
# Primary-group membership (Domain Users, Domain Computers) is NOT in the
# 'member' attribute -- it is implicit via primaryGroupID on each principal.
# Those groups are out of scope here and remain incomplete by design.

# Explicit dependency: this module calls Write-SafeCollectorLog. Importing it
# here makes the module self-sufficient (see the note in Groups.psm1).
Import-Module (Join-Path $PSScriptRoot "Logging.psm1") -Force

# ---------------------------------------------------------------------------
# The well-known privileged groups whose membership LegacyMCP expands.
# Single source for the collector: both Get-PrivilegedGroupsData (Groups.psm1)
# and Get-PrivilegedAccountsData (Users.psm1) consume this instead of keeping
# their own copy. Two lists that must stay identical are a silent drift risk,
# not harmless redundancy -- same reasoning as the P2 corollary.
#
# Live Mode keeps its own copy as a Python constant in live.py: the scripts
# there are strings executed on the DC and cannot import a PowerShell module.
# That leaves two sources total (one per mode) instead of four.
# ---------------------------------------------------------------------------
$script:PrivilegedGroupNames = @(
    "Domain Admins", "Enterprise Admins", "Schema Admins",
    "Administrators", "Account Operators", "Backup Operators",
    "Print Operators", "Server Operators"
)

function Get-PrivilegedGroupNames {
    # Returned without the array-preserving comma on purpose: the list is a
    # fixed 8 entries, never empty and never a single item, so there is no
    # unrolling hazard for callers that wrap the call in @().
    return $script:PrivilegedGroupNames
}

# ---------------------------------------------------------------------------
# Internal: classify an error record as "object not resolvable" vs anything
# else. Matching on the type NAME rather than the type itself avoids a hard
# dependency on the Microsoft.ActiveDirectory.Management assembly being
# loadable at parse time, and keeps the check working under mocks (P9).
# Anything not matched here is a real failure (connection, timeout, denied)
# and must propagate to the caller's per-group try/catch (P4).
# ---------------------------------------------------------------------------
function Test-ADObjectNotFound {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $typeName = ""
    if ($ErrorRecord.Exception) { $typeName = $ErrorRecord.Exception.GetType().FullName }
    if ($typeName -like "*IdentityNotFound*") { return $true }
    if ($typeName -like "*ObjectNotFound*")   { return $true }

    $categoryProp = $ErrorRecord.PSObject.Properties['CategoryInfo']
    if ($categoryProp -and $categoryProp.Value -and
        $categoryProp.Value.Category -eq 'ObjectNotFound') { return $true }

    return $false
}

# ---------------------------------------------------------------------------
# Internal: StrictMode-safe read of a possibly-absent property.
# A group with no members exposes no 'member' property at all; direct access
# would throw PropertyNotFoundStrict under Set-StrictMode -Version Latest
# (active in Collect-ADData.ps1).
# ---------------------------------------------------------------------------
function Get-SafePropertyValues {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $values = @()
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($prop -and $null -ne $prop.Value) { $values = @($prop.Value) }
    return ,$values
}

# ---------------------------------------------------------------------------
# Get-RawGroupMemberDNs -- the raw 'member' DN list for a group.
# Returns an array of DN strings (empty array for an empty group).
# Errors are NOT caught here: a failure to read the group itself is a real
# failure and belongs to the caller's per-group handler.
# ---------------------------------------------------------------------------
function Get-RawGroupMemberDNs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GroupDN,
        [hashtable]$CommonParams = @{}
    )

    $obj = Get-ADObject -Identity $GroupDN -Properties member @CommonParams
    $dns = Get-SafePropertyValues -InputObject $obj -Name 'member'

    # Truncation sentinel (P4). Ranging is handled by the AD module and was
    # verified in the field, so this is not expected to fire -- but a count
    # landing exactly on a known LDAP policy boundary is worth one line in the
    # log rather than a silent assumption. A group of exactly that size is a
    # harmless false positive.
    if ($dns.Count -eq 1000 -or $dns.Count -eq 1500 -or $dns.Count -eq 5000) {
        Write-SafeCollectorLog -Level WARN -Section "Groups" `
            -Message "Membership of '$GroupDN' = $($dns.Count) members, exactly on a known LDAP boundary -- verify it is not truncated"
    }

    return ,$dns
}

# ---------------------------------------------------------------------------
# Resolve-ADMemberByDN -- resolve one member DN to a normalized object.
# Returns $null when the DN is not resolvable (orphaned SID, tombstoned
# object, foreign principal): the caller counts it and moves on.
# Any other error propagates (P4).
#
# Enabled is read from the typed cmdlet as before. These are single-object
# -Identity lookups, not mass -Filter * pulls, so the constructed-property
# failure mode of task #131 does not apply here.
# ---------------------------------------------------------------------------
function Resolve-ADMemberByDN {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DN,
        [hashtable]$CommonParams = @{}
    )

    try {
        $obj = Get-ADObject -Identity $DN `
            -Properties objectClass, name, sAMAccountName @CommonParams
    } catch {
        if (Test-ADObjectNotFound -ErrorRecord $_) { return $null }
        throw
    }
    if ($null -eq $obj) { return $null }

    $objectClass = ""
    $ocValues = Get-SafePropertyValues -InputObject $obj -Name 'objectClass'
    if ($ocValues.Count -gt 0) { $objectClass = [string]$ocValues[-1] }

    $name = ""
    $nameValues = Get-SafePropertyValues -InputObject $obj -Name 'name'
    if ($nameValues.Count -gt 0) { $name = [string]$nameValues[0] }

    $sam = $null
    $samValues = Get-SafePropertyValues -InputObject $obj -Name 'sAMAccountName'
    if ($samValues.Count -gt 0) { $sam = [string]$samValues[0] }

    $enabled = $null
    if ($objectClass -eq 'user') {
        try {
            $enabled = (Get-ADUser -Identity $DN -Properties Enabled @CommonParams).Enabled
        } catch {
            if (-not (Test-ADObjectNotFound -ErrorRecord $_)) { throw }
        }
    } elseif ($objectClass -eq 'computer') {
        try {
            $enabled = (Get-ADComputer -Identity $DN -Properties Enabled @CommonParams).Enabled
        } catch {
            if (-not (Test-ADObjectNotFound -ErrorRecord $_)) { throw }
        }
    }

    return [PSCustomObject]@{
        DistinguishedName = $DN
        SamAccountName    = $sam
        Name              = $name
        ObjectClass       = $objectClass
        Enabled           = $enabled
    }
}

# ---------------------------------------------------------------------------
# Internal: recursive expansion worker.
# $Visited, $Collected and $Unresolved are mutated in place (reference
# semantics) so the cycle guard and both de-duplications span the whole descent.
# ---------------------------------------------------------------------------
function Expand-ADGroupMembership {
    param(
        [Parameter(Mandatory = $true)][string]$GroupDN,
        [hashtable]$CommonParams = @{},
        [Parameter(Mandatory = $true)][hashtable]$Visited,
        [Parameter(Mandatory = $true)]$Collected,
        [Parameter(Mandatory = $true)]$Unresolved,
        [Parameter(Mandatory = $true)][hashtable]$Counters
    )

    # Cycle guard: nested groups may form a loop, and the same group may be
    # reachable by several paths. Not an error -- a valid, if rare, AD layout.
    if ($Visited.ContainsKey($GroupDN)) {
        $Counters['Cycles']++
        return
    }
    $Visited[$GroupDN] = $true

    foreach ($dn in (Get-RawGroupMemberDNs -GroupDN $GroupDN -CommonParams $CommonParams)) {
        $member = Resolve-ADMemberByDN -DN $dn -CommonParams $CommonParams
        if ($null -eq $member) {
            # Keep the raw DN, not just a count: the caller turns it into an
            # explicit placeholder so the broken reference stays visible and
            # actionable instead of silently vanishing. De-duplicated for the
            # same reason as resolved members.
            if (-not $Unresolved.Contains($dn)) { $Unresolved[$dn] = $true }
            continue
        }
        if ($member.ObjectClass -eq 'group') {
            Expand-ADGroupMembership -GroupDN $member.DistinguishedName `
                -CommonParams $CommonParams -Visited $Visited `
                -Collected $Collected -Unresolved $Unresolved -Counters $Counters
        } elseif (-not $Collected.Contains($member.DistinguishedName)) {
            # De-duplicate: one principal reachable through several nesting
            # paths must appear once.
            $Collected[$member.DistinguishedName] = $member
        }
    }
}

# ---------------------------------------------------------------------------
# Get-GroupMembersRecursive -- full recursive expansion of a group, replacing
# Get-ADGroupMember -Recursive.
#
# Returns a single object with three properties:
#   Resolved   = the leaf principals (user/computer/other non-group),
#                de-duplicated by DistinguishedName
#   Unresolved = the raw DNs that could not be resolved, de-duplicated
#   Cycles     = nested groups skipped because already visited
#
# Returning an object rather than a bare array is deliberate: the previous
# ",@(...)" contract preserved the array through the pipeline but made
# @(Get-GroupMembersRecursive ...).Count silently return 1, which is exactly
# the bug that made every MemberCount come out as 1. Properties cannot unroll.
# ---------------------------------------------------------------------------
function Get-GroupMembersRecursive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GroupDN,
        [hashtable]$CommonParams = @{}
    )

    $visited    = @{}
    $collected  = [ordered]@{}
    $unresolved = [ordered]@{}
    $counters   = @{ Cycles = 0 }

    Expand-ADGroupMembership -GroupDN $GroupDN -CommonParams $CommonParams `
        -Visited $visited -Collected $collected `
        -Unresolved $unresolved -Counters $counters

    return [PSCustomObject]@{
        Resolved   = @($collected.Values)
        Unresolved = @($unresolved.Keys)
        Cycles     = $counters['Cycles']
    }
}

Export-ModuleMember -Function Get-RawGroupMemberDNs, Resolve-ADMemberByDN,
    Get-GroupMembersRecursive, Test-ADObjectNotFound, Get-SafePropertyValues,
    Get-PrivilegedGroupNames
