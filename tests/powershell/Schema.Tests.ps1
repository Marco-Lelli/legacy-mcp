# Pester tests for collector/modules/Schema.psm1 (task #130).
#
# Get-ADRootDSE / Get-ADObject are replaced by simple global stubs -- no real
# Active Directory required. Write-CollectorLog is also stubbed globally so
# Write-SafeCollectorLog (Logging.psm1) routes straight through it instead of
# falling back to native Write-Warning, making the exact warning content
# (level, section, message text) directly assertable instead of parsed out
# of the Warning stream.
#
# What is covered: the -Limit 500 default cap, the -Limit 0 unlimited
# override, custom -Limit values, the boundary at exactly the limit, warning
# content when the cap truncates, and that truncation keeps the first N
# results rather than an arbitrary subset. What is NOT covered: the real
# OID-prefix filtering logic against genuine schema data, since the stub
# supplies already-filtered-shape fake objects -- that part is unchanged by
# this task and was not touched.

Set-StrictMode -Version Latest

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot "..\..\collector\modules\Schema.psm1"
    Import-Module $script:ModulePath -Force

    function global:Get-ADRootDSE {
        param($Server, $Credential)
        [PSCustomObject]@{ schemaNamingContext = "CN=Schema,CN=Configuration,DC=contoso,DC=local" }
    }

    function global:Get-ADObject {
        param($SearchBase, $Filter, $Properties, $Server, $Credential)
        return $global:FakeSchemaObjects
    }

    function global:Write-CollectorLog {
        param([string]$Level, [string]$Section, [string]$Message)
        $script:CapturedLogs += [PSCustomObject]@{ Level = $Level; Section = $Section; Message = $Message }
    }

    function global:New-FakeExtension {
        param([int]$N)
        [PSCustomObject]@{
            lDAPDisplayName  = "customAttr$N"
            objectClass      = "attributeSchema"
            adminDescription = "test extension $N"
            governsID        = $null
            # Deliberately outside all three excluded OID prefixes
            # (1.2.840.113556 / 2.16.840.1.101.2 / 1.3.6.1.4.1.311) so these
            # fakes survive the real function's own Where-Object filter.
            attributeID      = "1.2.3.4.$N"
        }
    }
}

AfterAll {
    Remove-Item function:global:Get-ADRootDSE  -ErrorAction SilentlyContinue
    Remove-Item function:global:Get-ADObject   -ErrorAction SilentlyContinue
    Remove-Item function:global:Write-CollectorLog -ErrorAction SilentlyContinue
    Remove-Item function:global:New-FakeExtension  -ErrorAction SilentlyContinue
    Remove-Item variable:global:FakeSchemaObjects  -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Default cap (500) -- unlike Users/Computers (#128, unlimited by default),
# Schema keeps a default cap by design (task #130).
# ---------------------------------------------------------------------------
Describe "Get-SchemaExtensionsData -- default cap (500)" {
    BeforeEach { $script:CapturedLogs = @() }

    It "returns everything and does not warn when under the cap" {
        $global:FakeSchemaObjects = @(1..300 | ForEach-Object { New-FakeExtension -N $_ })
        $result = Get-SchemaExtensionsData
        @($result).Count | Should -Be 300
        $script:CapturedLogs.Count | Should -Be 0
    }

    It "returns exactly 500 and does not warn at the boundary" {
        $global:FakeSchemaObjects = @(1..500 | ForEach-Object { New-FakeExtension -N $_ })
        $result = Get-SchemaExtensionsData
        @($result).Count | Should -Be 500
        $script:CapturedLogs.Count | Should -Be 0
    }

    It "truncates to 500 and warns when the environment has more" {
        $global:FakeSchemaObjects = @(1..650 | ForEach-Object { New-FakeExtension -N $_ })
        $result = Get-SchemaExtensionsData
        @($result).Count | Should -Be 500
        $script:CapturedLogs.Count | Should -Be 1
        $script:CapturedLogs[0].Level   | Should -Be "WARN"
        $script:CapturedLogs[0].Section | Should -Be "Schema"
        $script:CapturedLogs[0].Message | Should -Match "650 found, truncated to 500"
        $script:CapturedLogs[0].Message | Should -Match "-Limit 0"
    }

    It "keeps the first 500 results in order, not an arbitrary subset" {
        $global:FakeSchemaObjects = @(1..600 | ForEach-Object { New-FakeExtension -N $_ })
        $result = @(Get-SchemaExtensionsData)
        $result[0].lDAPDisplayName  | Should -Be "customAttr1"
        $result[-1].lDAPDisplayName | Should -Be "customAttr500"
    }
}

# ---------------------------------------------------------------------------
# -Limit override
# ---------------------------------------------------------------------------
Describe "Get-SchemaExtensionsData -- -Limit override" {
    BeforeEach { $script:CapturedLogs = @() }

    It "-Limit 0 returns everything, no warning, even far past the default cap" {
        $global:FakeSchemaObjects = @(1..900 | ForEach-Object { New-FakeExtension -N $_ })
        $result = Get-SchemaExtensionsData -Limit 0
        @($result).Count | Should -Be 900
        $script:CapturedLogs.Count | Should -Be 0
    }

    It "a custom -Limit truncates and warns using its own threshold, not 500" {
        $global:FakeSchemaObjects = @(1..20 | ForEach-Object { New-FakeExtension -N $_ })
        $result = Get-SchemaExtensionsData -Limit 10
        @($result).Count | Should -Be 10
        $script:CapturedLogs.Count | Should -Be 1
        $script:CapturedLogs[0].Message | Should -Match "20 found, truncated to 10"
    }

    It "a custom -Limit with results already under it does not warn" {
        $global:FakeSchemaObjects = @(1..5 | ForEach-Object { New-FakeExtension -N $_ })
        $result = Get-SchemaExtensionsData -Limit 10
        @($result).Count | Should -Be 5
        $script:CapturedLogs.Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# Field mapping -- unchanged by this task, spot-checked for a clean baseline.
# ---------------------------------------------------------------------------
Describe "Get-SchemaExtensionsData -- field mapping" {

    It "maps all five fields onto the output object" {
        $global:FakeSchemaObjects = @([PSCustomObject]@{
            lDAPDisplayName  = "myCustomAttr"
            objectClass      = "attributeSchema"
            adminDescription = "A custom attribute"
            governsID        = $null
            attributeID      = "1.2.3.4.5.6"
        })
        $result = Get-SchemaExtensionsData
        $result.lDAPDisplayName  | Should -Be "myCustomAttr"
        $result.ObjectClass      | Should -Be "attributeSchema"
        $result.AdminDescription | Should -Be "A custom attribute"
        $result.GovernsID        | Should -BeNullOrEmpty
        $result.AttributeID      | Should -Be "1.2.3.4.5.6"
    }
}
