# Pester tests for collector/modules/Users.psm1 -- Get-UsersData (task #135).
#
# Get-ADUser is replaced by a simple global stub -- no real Active Directory
# required. Write-CollectorLog is also stubbed globally so
# Write-SafeCollectorLog (Logging.psm1) routes straight through it instead of
# falling back to native Write-Warning, making the exact warning content
# (level, section, message text) directly assertable instead of parsed out
# of the Warning stream. Same pattern as Schema.Tests.ps1 (task #130).
#
# Scope: only PasswordNotRequired's derivation from userAccountControl
# (task #135 -- it used to read the raw property directly instead of the
# normalized $uac already used by the other 4 derived fields, fabricating
# $false instead of null when userAccountControl itself is unreadable).
# The other derived fields (Enabled, PasswordNeverExpires,
# TrustedForDelegation, TrustedToAuthForDelegation, CannotChangePassword)
# are exercised here only incidentally, as part of verifying nothing else
# regressed.

Set-StrictMode -Version Latest

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot "..\..\collector\modules\Users.psm1"
    Import-Module $script:ModulePath -Force

    function global:Get-ADUser {
        param($Filter, $Properties)
        return $global:FakeUsers
    }

    function global:Write-CollectorLog {
        param([string]$Level, [string]$Section, [string]$Message)
        $script:CapturedLogs += [PSCustomObject]@{ Level = $Level; Section = $Section; Message = $Message }
    }

    function global:New-FakeUser {
        param([string]$Name, $Uac, [bool]$CannotChangePassword = $false)
        [PSCustomObject]@{
            SamAccountName             = $Name
            DisplayName                = $Name
            UserPrincipalName          = "$Name@contoso.local"
            DistinguishedName          = "CN=$Name,DC=contoso,DC=local"
            mail                       = $null
            Enabled                    = $null   # constructed property -- ignored, derived from raw uac instead
            PasswordNeverExpires       = $null
            LockedOut                  = $false
            LastLogonDate              = $null
            PasswordLastSet            = $null
            Description                = $null
            adminCount                 = $null
            SIDHistory                 = @()
            TrustedForDelegation       = $null
            TrustedToAuthForDelegation = $null
            "msDS-AllowedToDelegateTo" = @()
            userAccountControl         = $Uac
            homeDrive                  = $null
            homeDirectory              = $null
            primaryGroupID             = 513
            CannotChangePassword       = $CannotChangePassword
        }
    }
}

AfterAll {
    Remove-Item function:global:Get-ADUser       -ErrorAction SilentlyContinue
    Remove-Item function:global:Write-CollectorLog -ErrorAction SilentlyContinue
    Remove-Item function:global:New-FakeUser     -ErrorAction SilentlyContinue
    Remove-Item variable:global:FakeUsers        -ErrorAction SilentlyContinue
}

Describe "Get-UsersData -- PasswordNotRequired derived from normalized uac (task #135)" {
    BeforeEach { $script:CapturedLogs = @() }

    It "is false when userAccountControl is readable and PASSWD_NOTREQD (0x20) is not set" {
        $global:FakeUsers = @(New-FakeUser -Name "alice" -Uac 512)   # NORMAL_ACCOUNT only
        $result = Get-UsersData
        $result.PasswordNotRequired | Should -Be $false
    }

    It "is true when userAccountControl is readable and PASSWD_NOTREQD (0x20) is set" {
        $global:FakeUsers = @(New-FakeUser -Name "bob" -Uac 544)     # 0x200 | 0x20
        $result = Get-UsersData
        $result.PasswordNotRequired | Should -Be $true
    }

    It "is explicit null -- not a fabricated false -- when userAccountControl itself is unreadable" {
        $global:FakeUsers = @(New-FakeUser -Name "carol" -Uac $null)
        $result = Get-UsersData
        $result.PasswordNotRequired | Should -Be $null
        # The other 4 fields sharing the same cause must be null too --
        # this is the pre-existing, already-correct behavior being matched.
        $result.Enabled                    | Should -Be $null
        $result.PasswordNeverExpires       | Should -Be $null
        $result.TrustedForDelegation       | Should -Be $null
        $result.TrustedToAuthForDelegation | Should -Be $null
    }

    It "shares the existing uacNullCount warning -- no separate warning is raised" {
        $global:FakeUsers = @(
            (New-FakeUser -Name "alice" -Uac 512),
            (New-FakeUser -Name "carol" -Uac $null)
        )
        Get-UsersData | Out-Null
        $uacWarnings = @($script:CapturedLogs | Where-Object { $_.Message -match "userAccountControl not available" })
        $uacWarnings.Count | Should -Be 1
        $uacWarnings[0].Level   | Should -Be "WARN"
        $uacWarnings[0].Section | Should -Be "Users"
        $uacWarnings[0].Message | Should -Match "1 users out of 2 collected"
        $uacWarnings[0].Message | Should -Match "PasswordNotRequired"
    }
}
