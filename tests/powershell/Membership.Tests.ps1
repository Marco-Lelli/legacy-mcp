# Pester tests for collector/modules/Membership.psm1 (task #134).
#
# These run without a real Active Directory: Get-ADObject / Get-ADUser /
# Get-ADComputer are replaced by data-driven stubs backed by $global:FakeAD.
# The stubs are defined in the global scope because an imported module
# resolves an unqualified command through the session scope at call time.
#
# What is genuinely covered here: per-member fault isolation, the cycle
# guard, de-duplication across nesting paths, error classification, and
# StrictMode-safe handling of absent/empty attributes.
#
# What is NOT covered and cannot be, without a real directory: whether the
# AD module returns the complete member list. That was settled empirically
# in the field instead (6109 DNs on a group where Get-ADGroupMember failed).

Set-StrictMode -Version Latest

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot "..\..\collector\modules\Membership.psm1"
    Import-Module $script:ModulePath -Force

    # -- fake directory -----------------------------------------------------
    function global:New-FakeADObject {
        param([hashtable]$Props)
        $o = [PSCustomObject]@{}
        foreach ($k in $Props.Keys) {
            $o | Add-Member -NotePropertyName $k -NotePropertyValue $Props[$k]
        }
        return $o
    }

    function global:Throw-NotFound {
        param([string]$Identity)
        $ex = New-Object System.Management.Automation.ItemNotFoundException `
            "Cannot find an object with identity: '$Identity'"
        $er = New-Object System.Management.Automation.ErrorRecord `
            $ex, "ADIdentityNotFoundException", `
            ([System.Management.Automation.ErrorCategory]::ObjectNotFound), $Identity
        throw $er
    }

    function global:Get-ADObject {
        param(
            [Parameter(Mandatory = $true)][string]$Identity,
            [string[]]$Properties, [string]$Server, $Credential
        )
        if ($global:FakeADFailHard -contains $Identity) {
            throw "The server is not operational"      # connection-class failure
        }
        if (-not $global:FakeAD.ContainsKey($Identity)) { Throw-NotFound -Identity $Identity }
        return $global:FakeAD[$Identity]
    }

    function global:Get-ADUser {
        param(
            [Parameter(Mandatory = $true)][string]$Identity,
            [string[]]$Properties, [string]$Server, $Credential
        )
        if (-not $global:FakeAD.ContainsKey($Identity)) { Throw-NotFound -Identity $Identity }
        return $global:FakeAD[$Identity]
    }

    function global:Get-ADComputer {
        param(
            [Parameter(Mandatory = $true)][string]$Identity,
            [string[]]$Properties, [string]$Server, $Credential
        )
        if (-not $global:FakeAD.ContainsKey($Identity)) { Throw-NotFound -Identity $Identity }
        return $global:FakeAD[$Identity]
    }
}

Describe "Get-RawGroupMemberDNs" {
    BeforeEach { $global:FakeAD = @{}; $global:FakeADFailHard = @() }

    It "returns an empty array for a group with no member property at all" {
        # StrictMode would throw on direct property access -- the guard must hold.
        $global:FakeAD["CN=Empty,DC=x"] = New-FakeADObject @{ name = "Empty" }
        $r = Get-RawGroupMemberDNs -GroupDN "CN=Empty,DC=x"
        $r.Count | Should -Be 0
    }

    It "returns an empty array when member is present but null" {
        $global:FakeAD["CN=G,DC=x"] = New-FakeADObject @{ name = "G"; member = $null }
        (Get-RawGroupMemberDNs -GroupDN "CN=G,DC=x").Count | Should -Be 0
    }

    It "returns a single-element array for a one-member group" {
        $global:FakeAD["CN=G,DC=x"] = New-FakeADObject @{ member = "CN=U1,DC=x" }
        $r = Get-RawGroupMemberDNs -GroupDN "CN=G,DC=x"
        $r.Count | Should -Be 1
        $r[0]    | Should -Be "CN=U1,DC=x"
    }

    It "returns every DN for a multi-member group" {
        $global:FakeAD["CN=G,DC=x"] = New-FakeADObject @{
            member = @("CN=U1,DC=x", "CN=U2,DC=x", "CN=U3,DC=x")
        }
        (Get-RawGroupMemberDNs -GroupDN "CN=G,DC=x").Count | Should -Be 3
    }

    It "propagates a connection-class failure instead of returning empty" {
        $global:FakeADFailHard = @("CN=G,DC=x")
        { Get-RawGroupMemberDNs -GroupDN "CN=G,DC=x" } | Should -Throw
    }

    It "returns a countable array without needing an @() wrapper" {
        # Regression guard: the function returns ",$dns" so the array survives
        # the pipeline whole. That makes @(Get-RawGroupMemberDNs ...) nest one
        # level deeper and count 1 for ANY group -- the bug that made every
        # MemberCount come out as 1. Callers must assign, then count.
        $global:FakeAD["CN=G,DC=x"] = New-FakeADObject @{
            member = @("CN=U1,DC=x", "CN=U2,DC=x", "CN=U3,DC=x")
        }
        $dns = Get-RawGroupMemberDNs -GroupDN "CN=G,DC=x"
        $dns.Count            | Should -Be 3
        $dns -is [array]      | Should -BeTrue
        @($dns).Count         | Should -Be 3
    }
}

Describe "Test-ADObjectNotFound" {
    BeforeEach { $global:FakeAD = @{}; $global:FakeADFailHard = @() }

    It "classifies an ObjectNotFound error record as not-found" {
        try { Throw-NotFound -Identity "CN=Ghost,DC=x" } catch { $rec = $_ }
        Test-ADObjectNotFound -ErrorRecord $rec | Should -BeTrue
    }

    It "does not classify a connection failure as not-found" {
        try { throw "The server is not operational" } catch { $rec = $_ }
        Test-ADObjectNotFound -ErrorRecord $rec | Should -BeFalse
    }
}

Describe "Resolve-ADMemberByDN" {
    BeforeEach { $global:FakeAD = @{}; $global:FakeADFailHard = @() }

    It "resolves a user and carries Enabled through" {
        $global:FakeAD["CN=U1,DC=x"] = New-FakeADObject @{
            objectClass = "user"; name = "User One"
            sAMAccountName = "u1"; Enabled = $true
        }
        $m = Resolve-ADMemberByDN -DN "CN=U1,DC=x"
        $m.ObjectClass    | Should -Be "user"
        $m.SamAccountName | Should -Be "u1"
        $m.Enabled        | Should -BeTrue
    }

    It "returns null for an unresolvable DN instead of throwing" {
        Resolve-ADMemberByDN -DN "CN=Orphan,DC=x" | Should -BeNullOrEmpty
    }

    It "leaves Enabled null for a non-user, non-computer member" {
        $global:FakeAD["CN=FSP,DC=x"] = New-FakeADObject @{
            objectClass = "foreignSecurityPrincipal"; name = "S-1-5-21-x"
        }
        $m = Resolve-ADMemberByDN -DN "CN=FSP,DC=x"
        $m.ObjectClass | Should -Be "foreignSecurityPrincipal"
        $m.Enabled     | Should -BeNullOrEmpty
    }

    It "propagates a connection-class failure (P4)" {
        $global:FakeADFailHard = @("CN=U1,DC=x")
        { Resolve-ADMemberByDN -DN "CN=U1,DC=x" } | Should -Throw
    }
}

Describe "Get-GroupMembersRecursive" {
    BeforeEach { $global:FakeAD = @{}; $global:FakeADFailHard = @() }

    It "expands nested groups down to leaf principals" {
        $global:FakeAD["CN=Top,DC=x"]  = New-FakeADObject @{ objectClass = "group"; name = "Top";  member = @("CN=Sub,DC=x", "CN=U1,DC=x") }
        $global:FakeAD["CN=Sub,DC=x"]  = New-FakeADObject @{ objectClass = "group"; name = "Sub";  member = @("CN=U2,DC=x") }
        $global:FakeAD["CN=U1,DC=x"]   = New-FakeADObject @{ objectClass = "user";  name = "U1"; sAMAccountName = "u1"; Enabled = $true }
        $global:FakeAD["CN=U2,DC=x"]   = New-FakeADObject @{ objectClass = "user";  name = "U2"; sAMAccountName = "u2"; Enabled = $true }

        $r = Get-GroupMembersRecursive -GroupDN "CN=Top,DC=x"
        $r.Resolved.Count | Should -Be 2
        ($r.Resolved.SamAccountName | Sort-Object) -join "," | Should -Be "u1,u2"
    }

    It "does not loop forever on a membership cycle" {
        # A contains B, B contains A -- valid AD, must terminate.
        $global:FakeAD["CN=A,DC=x"]  = New-FakeADObject @{ objectClass = "group"; name = "A"; member = @("CN=B,DC=x", "CN=U1,DC=x") }
        $global:FakeAD["CN=B,DC=x"]  = New-FakeADObject @{ objectClass = "group"; name = "B"; member = @("CN=A,DC=x") }
        $global:FakeAD["CN=U1,DC=x"] = New-FakeADObject @{ objectClass = "user"; name = "U1"; sAMAccountName = "u1"; Enabled = $true }

        $r = Get-GroupMembersRecursive -GroupDN "CN=A,DC=x"
        $r.Resolved.Count | Should -Be 1
        $r.Cycles         | Should -BeGreaterThan 0
    }

    It "de-duplicates a principal reachable through two nesting paths" {
        $global:FakeAD["CN=Top,DC=x"] = New-FakeADObject @{ objectClass = "group"; name = "Top"; member = @("CN=S1,DC=x", "CN=S2,DC=x") }
        $global:FakeAD["CN=S1,DC=x"]  = New-FakeADObject @{ objectClass = "group"; name = "S1";  member = @("CN=U1,DC=x") }
        $global:FakeAD["CN=S2,DC=x"]  = New-FakeADObject @{ objectClass = "group"; name = "S2";  member = @("CN=U1,DC=x") }
        $global:FakeAD["CN=U1,DC=x"]  = New-FakeADObject @{ objectClass = "user"; name = "U1"; sAMAccountName = "u1"; Enabled = $true }

        (Get-GroupMembersRecursive -GroupDN "CN=Top,DC=x").Resolved.Count | Should -Be 1
    }

    It "KEEPS the good members when one member is unresolvable (task #134 core)" {
        # This is the whole point of the redesign: Get-ADGroupMember would have
        # lost all three. Here the orphan costs exactly itself.
        $global:FakeAD["CN=Adm,DC=x"] = New-FakeADObject @{
            objectClass = "group"; name = "Administrators"
            member = @("CN=U1,DC=x", "CN=Orphan,DC=x", "CN=U2,DC=x")
        }
        $global:FakeAD["CN=U1,DC=x"] = New-FakeADObject @{ objectClass = "user"; name = "U1"; sAMAccountName = "u1"; Enabled = $true }
        $global:FakeAD["CN=U2,DC=x"] = New-FakeADObject @{ objectClass = "user"; name = "U2"; sAMAccountName = "u2"; Enabled = $false }
        # CN=Orphan deliberately absent from the fake directory.

        $r = Get-GroupMembersRecursive -GroupDN "CN=Adm,DC=x"
        $r.Resolved.Count | Should -Be 2
        ($r.Resolved.SamAccountName | Sort-Object) -join "," | Should -Be "u1,u2"
    }

    It "surfaces the raw DN of an unresolvable member, not just a count" {
        # The DN is the actionable datum: it identifies the broken reference to
        # clean up in AD. Losing it was the gap this change closes.
        $global:FakeAD["CN=Adm,DC=x"] = New-FakeADObject @{
            objectClass = "group"; name = "Administrators"
            member = @("CN=U1,DC=x", "CN=Orphan,DC=x")
        }
        $global:FakeAD["CN=U1,DC=x"] = New-FakeADObject @{ objectClass = "user"; name = "U1"; sAMAccountName = "u1"; Enabled = $true }

        $r = Get-GroupMembersRecursive -GroupDN "CN=Adm,DC=x"
        $r.Unresolved.Count | Should -Be 1
        $r.Unresolved[0]    | Should -Be "CN=Orphan,DC=x"
    }

    It "de-duplicates an unresolvable DN reachable through two nesting paths" {
        $global:FakeAD["CN=Top,DC=x"] = New-FakeADObject @{ objectClass = "group"; name = "Top"; member = @("CN=S1,DC=x", "CN=S2,DC=x") }
        $global:FakeAD["CN=S1,DC=x"]  = New-FakeADObject @{ objectClass = "group"; name = "S1";  member = @("CN=Orphan,DC=x") }
        $global:FakeAD["CN=S2,DC=x"]  = New-FakeADObject @{ objectClass = "group"; name = "S2";  member = @("CN=Orphan,DC=x") }

        (Get-GroupMembersRecursive -GroupDN "CN=Top,DC=x").Unresolved.Count | Should -Be 1
    }

    It "returns empty arrays for an empty group without throwing" {
        $global:FakeAD["CN=Empty,DC=x"] = New-FakeADObject @{ objectClass = "group"; name = "Empty" }
        $r = Get-GroupMembersRecursive -GroupDN "CN=Empty,DC=x"
        $r.Resolved.Count   | Should -Be 0
        $r.Unresolved.Count | Should -Be 0
    }

    It "exposes Resolved/Unresolved as real arrays, immune to pipeline unrolling" {
        # Regression guard for the ",@(...)" trap that made every MemberCount
        # come out as 1. Properties of an object cannot unroll.
        $global:FakeAD["CN=G,DC=x"]  = New-FakeADObject @{ objectClass = "group"; name = "G"; member = @("CN=U1,DC=x", "CN=O1,DC=x", "CN=O2,DC=x") }
        $global:FakeAD["CN=U1,DC=x"] = New-FakeADObject @{ objectClass = "user"; name = "U1"; sAMAccountName = "u1"; Enabled = $true }

        $r = Get-GroupMembersRecursive -GroupDN "CN=G,DC=x"
        @($r.Resolved).Count   | Should -Be 1
        @($r.Unresolved).Count | Should -Be 2
        $r.Unresolved -is [array] | Should -BeTrue
    }
}

Describe "Get-PrivilegedGroupNames" {
    It "is the single collector-side source of the 8 well-known groups" {
        $names = @(Get-PrivilegedGroupNames)
        $names.Count | Should -Be 8
        $names | Should -Contain "Domain Admins"
        $names | Should -Contain "Server Operators"
    }
}
