# Users.psm1 — AD User data collection helpers

# Explicit dependencies. Importing them here makes the module self-sufficient,
# so a standalone import cannot fail later with CommandNotFoundException
# mid-collection (task #134 field incident).
#   Logging.psm1    -> Write-SafeCollectorLog
#   Membership.psm1 -> Get-PrivilegedGroupNames, Get-GroupMembersRecursive
# Leaving the second one implicit worked only as long as the host script
# happened to import it first; a -Force re-import from another module was
# enough to break it.
Import-Module (Join-Path $PSScriptRoot "Logging.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "Membership.psm1") -Force

function Get-UsersData {
    [CmdletBinding()]
    param(
        [hashtable]$CommonParams = @{},
        [int]$Limit = 0            # 0 = no limit (default). >0 for test/debug use only.
    )

    $users = Get-ADUser -Filter * -Properties Enabled, PasswordNeverExpires, LockedOut,
        LastLogonDate, PasswordLastSet, Description, mail, adminCount, SIDHistory,
        TrustedForDelegation, TrustedToAuthForDelegation, "msDS-AllowedToDelegateTo",
        userAccountControl, homeDirectory, homeDrive, primaryGroupID,
        CannotChangePassword @CommonParams

    # Apply the limit ONLY when explicitly requested (>0).
    # Note: Select-Object -First 0 would return zero objects, so the guard is necessary.
    if ($Limit -gt 0) { $users = $users | Select-Object -First $Limit }

    $cannotChangePasswordNullCount = 0
    $uacNullCount = 0

    $users | ForEach-Object {
            # Derived from userAccountControl bits, not from the constructed
            # properties -- those return $null on most objects when
            # userAccountControl is also requested explicitly in a mass
            # Get-ADUser -Filter * pull (task #131, field-confirmed on AUSL
            # Romagna, 11105 users). If userAccountControl itself is $null
            # (seen structurally on a whole domain in a later field test,
            # cause not yet determined -- see task #133), the 5 derived
            # fields stay $null explicitly instead of defaulting to a
            # plausible-looking but fabricated boolean (task #135:
            # PasswordNotRequired was still reading the raw property here,
            # fabricating $false instead of null -- brought in line with
            # the other 4).
            if ($_.userAccountControl -ne $null) {
                $uac                        = [int]$_.userAccountControl
                $enabled                    = (-not [bool]($uac -band 0x2))       # ACCOUNTDISABLE
                $passwordNeverExpires       = [bool]($uac -band 0x10000)          # DONT_EXPIRE_PASSWORD
                $trustedForDelegation       = [bool]($uac -band 0x80000)          # TRUSTED_FOR_DELEGATION
                $trustedToAuthForDelegation = [bool]($uac -band 0x1000000)        # TRUSTED_TO_AUTH_FOR_DELEGATION
                $passwordNotRequired        = [bool]($uac -band 0x20)             # PASSWD_NOTREQD
            } else {
                $uacNullCount++
                $enabled                    = $null
                $passwordNeverExpires       = $null
                $trustedForDelegation       = $null
                $trustedToAuthForDelegation = $null
                $passwordNotRequired        = $null
            }

            [PSCustomObject]@{
                SamAccountName               = $_.SamAccountName
                DisplayName                  = $_.DisplayName
                UserPrincipalName            = $_.UserPrincipalName
                DistinguishedName            = $_.DistinguishedName
                Mail                         = $_.mail
                Enabled                      = $enabled
                PasswordNeverExpires         = $passwordNeverExpires
                LockedOut                    = $_.LockedOut
                LastLogonDate                = $_.LastLogonDate
                PasswordLastSet              = $_.PasswordLastSet
                Description                  = $_.Description
                AdminCount                   = $_.adminCount
                SIDHistory                   = @($_.SIDHistory | ForEach-Object { $_.Value })
                TrustedForDelegation         = $trustedForDelegation
                TrustedToAuthForDelegation   = $trustedToAuthForDelegation
                AllowedToDelegateTo          = @($_."msDS-AllowedToDelegateTo") -join ", "
                PasswordNotRequired          = $passwordNotRequired
                HomeDrive                    = $_.homeDrive
                HomeDirectory                = $_.homeDirectory
                PrimaryGroupID               = $_.primaryGroupID
                CannotChangePassword         = if ($_.CannotChangePassword -ne $null) {
                    [bool]$_.CannotChangePassword
                } else {
                    $cannotChangePasswordNullCount++
                    $false
                }
            }
        }

    # @() guard: Get-ADUser -Filter * can return a single (non-array) object
    # when exactly one result matches (e.g. a -Limit 1 test/debug run) -- under
    # Set-StrictMode -Version Latest (active in Collect-ADData.ps1), .Count on
    # a bare PSCustomObject throws "property 'Count' cannot be found".
    if ($cannotChangePasswordNullCount -gt 0) {
        Write-SafeCollectorLog -Level WARN -Section "Users" `
            -Message "CannotChangePassword was null for $cannotChangePasswordNullCount users out of $(@($users).Count) collected - fallback to false applied for all - see task #133"
    }
    if ($uacNullCount -gt 0) {
        Write-SafeCollectorLog -Level WARN -Section "Users" `
            -Message "userAccountControl not available for $uacNullCount users out of $(@($users).Count) collected - Enabled/PasswordNeverExpires/TrustedForDelegation/TrustedToAuthForDelegation/PasswordNotRequired set to null for these users, not calculable - cause to be investigated separately (permissions/DC)"
    }
}

function Get-PrivilegedAccountsData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    # Single source shared with Get-PrivilegedGroupsData (Membership.psm1).
    $groups = @(Get-PrivilegedGroupNames)

    # Task #134: recursive expansion via Get-GroupMembersRecursive instead of
    # Get-ADGroupMember -Recursive. Previously a single unresolvable member
    # discarded an entire privileged group, silently under-reporting the
    # account count with nothing in the JSON to show it had happened.
    #
    # No placeholder is emitted here, by design: this section feeds a COUNT of
    # privileged accounts (Collect-ADData.ps1 and the "total" of query_page in
    # tools/users.py), and the whole point of task #134 was to make that count
    # accurate. The unresolved DNs are not lost -- they are visible as
    # placeholders in privileged_groups (same 8 groups, same expansion) and in
    # group_members.
    $seen = @{}
    $unresolvableTotal = 0
    $groupsFailed = @()

    foreach ($group in $groups) {
        try {
            $groupObj = Get-ADGroup -Identity $group @CommonParams
            $expansion = Get-GroupMembersRecursive -GroupDN $groupObj.DistinguishedName `
                -CommonParams $CommonParams
            $unresolvableTotal += $expansion.Unresolved.Count

            $expansion.Resolved |
                Where-Object { $_.ObjectClass -eq "user" } |
                ForEach-Object {
                    if (-not $seen[$_.SamAccountName]) {
                        $seen[$_.SamAccountName] = $true
                        [PSCustomObject]@{
                            SamAccountName = $_.SamAccountName
                            Group          = $group
                        }
                    }
                }
        } catch {
            $groupsFailed += $group
            Write-SafeCollectorLog -Level WARN -Section "Privileged Accounts" `
                -Message "Group '$group' not enumerated: $_"
        }
    }

    if ($unresolvableTotal -gt 0) {
        Write-SafeCollectorLog -Level WARN -Section "Privileged Accounts" `
            -Message "$unresolvableTotal unresolvable members during the expansion of privileged groups -- excluded from this count to avoid skewing it, visible as placeholders in privileged_groups and group_members"
    }
    if ($groupsFailed.Count -gt 0) {
        Write-SafeCollectorLog -Level WARN -Section "Privileged Accounts" `
            -Message "Privileged groups NOT enumerated ($($groupsFailed.Count)/$($groups.Count)): $($groupsFailed -join ', ') -- the privileged account count is incomplete"
    }
}

Export-ModuleMember -Function Get-UsersData, Get-PrivilegedAccountsData
