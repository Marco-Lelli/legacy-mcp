# Pester tests for the pure/isolable helper functions in
# installer/Manage-Workspaces.ps1 (task #127, Fase 2).
#
# Manage-Workspaces.ps1 CANNOT be dot-sourced directly for testing -- verified
# empirically before writing this file:
#   - [CmdletBinding(DefaultParameterSetName='List')] requires one of
#     -List/-Add/-Remove/-Validate/-RepairMetadata to bind at all.
#   - Line ~110 calls Resolve-ConfigPath at the TOP LEVEL of the script (a
#     real registry lookup), before any function definition a test might
#     want to mock first.
#   - The script ends with an entry-point dispatcher containing 17 `exit`
#     statements across its Invoke-* functions. `exit` inside a dot-sourced
#     script terminates the PESTER PROCESS, not just the script -- confirmed
#     by inspection, not risked empirically.
#
# Instead, the target functions are extracted via the PowerShell AST and
# loaded with Invoke-Expression. Only the function DEFINITIONS execute --
# no parameter binding, no top-level Resolve-ConfigPath call, no dispatcher.
# This also means only the functions listed below exist in this file's
# scope; anything calling Write-ConfigRaw or other script-scoped helpers is
# out of reach here by design (side-effect functions, out of scope for
# Fase 1's priority list). Get-Forests is the one exception that needs a
# dependency stub: it calls Read-ConfigRaw, which is provided per-test as a
# global function override (Describe "Get-Forests" below) instead of being
# extracted, since its real implementation reads an actual file.
#
# Read-JsonFile, Write-JsonFile, Backup-JsonFile and Test-DcReachable (task
# #127, Fase 2 tranche 2) are also safe to extract into this SAME shared
# pool: none of them call any other function defined in Manage-Workspaces.ps1
# -- only external cmdlets/.NET methods that are never redefined elsewhere
# in this file. Test-DcReachable is stubbed the same way
# Get-ConfigPathFromHive already stubs Test-Path/Get-ItemProperty below
# (shadow the external cmdlet, Test-NetConnection here, with a global
# function per test).
#
# Read-ConfigRaw, Write-ConfigRaw and Remove-ForestFromConfig are
# deliberately NOT added to this shared pool, even though Remove-
# ForestFromConfig calls only Read-ConfigRaw/Write-ConfigRaw and nothing
# else. Verified empirically (scope-resolution repro under Pester 5.7.1,
# see delta note for this session) before writing their tests: once a
# function is extracted into this scope via Invoke-Expression, a LATER
# `function global:SameName { ... }` stub defined inside an It block does
# NOT shadow it -- the pre-existing script-scope definition silently wins
# and the stub has no effect at all. Get-Forests's own stubbing of
# Read-ConfigRaw below works only because Read-ConfigRaw is never extracted
# anywhere in this shared pool. Adding the REAL Read-ConfigRaw/Write-
# ConfigRaw here would therefore silently break Get-Forests's stub-based
# tests. Their own Describe blocks each run an independent, isolated AST
# extraction instead (own BeforeAll, own Invoke-Expression), so nothing here
# can ever collide with a stub defined elsewhere.
#
# HISTORICAL NOTE -- Test-Path scope leak (found and fixed same session,
# task #127 Fase 2 tranche 2). The Get-ConfigPathFromHive and
# Resolve-ConfigPath Describe blocks below stub Test-Path/Get-ItemProperty
# globally for their own tests. Their AfterAll used to remove the stub with
# a bare `Remove-Item function:global:Test-Path` -- verified empirically
# that this does NOT restore the real Test-Path cmdlet for the rest of the
# Pester run within this file: any LATER Describe block calling a bare,
# unstubbed `Test-Path` from the parent (Pester) process got $false
# unconditionally, never the real filesystem answer. Confirmed with a
# minimal repro outside this file and, concretely, with leaked
# lmcp-repair-*/lmcp-validate-* directories under %TEMP% dating back to the
# session that introduced those two Describe blocks -- their own AfterAll
# cleanup (`if (... -and (Test-Path $script:WorkDir)) { Remove-Item ... }`)
# was silently skipping itself on every full-suite run, because Test-Path
# always read as $false there too.
#
# Verified before fixing that this never produced a false-positive test
# result: grepped every Test-Path call site in the real script against
# every pre-existing Describe block running after these two, and none of
# them fed into a `Should` assertion -- either the calling function was
# never invoked from a block that ran after the leak started (ConvertFrom-
# ForestsText, Get-Forests, Get-ConfigSections, Format-ForestBlock,
# Get-JsonProperty, Resolve-Module never call Test-Path at all), or the
# Test-Path call happened inside an isolated child process
# (Invoke-RepairMetadata, Invoke-Validate), or it was in an AfterAll
# cleanup guard with no assertion attached to it. Confirmed empirically too:
# running the suite with the leak present vs. with an explicit working
# restore inserted produced byte-identical per-test results, 86/86 both
# ways. Disk hygiene only -- never test correctness.
#
# Fixed: both AfterAll blocks below now restore Test-Path via a
# module-qualified proxy (Microsoft.PowerShell.Management\Test-Path @args),
# which cannot itself be shadowed by a same-named function, instead of a
# bare Remove-Item. Test-Path is now genuinely back to real cmdlet behavior
# for every Describe block that runs after these two -- the AfterAll
# cleanup guards elsewhere in this file (`if (... -and (Test-Path ...))`)
# now work as originally intended, and the [System.IO.File]::Exists() /
# [System.IO.Directory]::Exists() workarounds used elsewhere in the newer
# Describe blocks remain in place (harmless, and independent of this fix)
# rather than being reverted.

Set-StrictMode -Version Latest

BeforeAll {
    $script:SourcePath = (Resolve-Path (Join-Path $PSScriptRoot "..\..\installer\Manage-Workspaces.ps1")).Path

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:SourcePath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "Failed to parse Manage-Workspaces.ps1: $($parseErrors -join '; ')"
    }

    $targetFunctions = @(
        'Get-ConfigPathFromHive', 'Resolve-ConfigPath',
        'ConvertFrom-ForestsText', 'Get-ConfigSections', 'Format-ForestBlock',
        'Get-JsonProperty', 'Resolve-Module', 'Get-Forests',
        'Read-JsonFile', 'Write-JsonFile', 'Backup-JsonFile', 'Test-DcReachable'
    )
    $funcAsts = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $targetFunctions -contains $node.Name
    }, $true)

    if ($funcAsts.Count -ne $targetFunctions.Count) {
        $found   = @($funcAsts | ForEach-Object { $_.Name })
        $missing = $targetFunctions | Where-Object { $found -notcontains $_ }
        throw "Expected function(s) not found in Manage-Workspaces.ps1: $($missing -join ', ')"
    }

    # Joined and evaluated once: defines all 12 functions in this scope, with
    # no other top-level script code (param block, $ConfigFile, dispatcher).
    $extracted = ($funcAsts | ForEach-Object { $_.Extent.Text }) -join "`n`n"
    Invoke-Expression $extracted
}

# ---------------------------------------------------------------------------
# Get-ConfigPathFromHive -- single registry hive read.
# Test-Path / Get-ItemProperty are shadowed globally, scoped to this Describe
# only (removed in AfterAll), so no other block is affected and no real
# registry key is ever touched.
# ---------------------------------------------------------------------------
Describe "Get-ConfigPathFromHive" {
    BeforeAll {
        function global:Test-Path {
            param($Path)
            return $global:FakeRegistry.ContainsKey($Path)
        }
        function global:Get-ItemProperty {
            param($Path, $ErrorAction)
            if ($global:FakeRegistry[$Path] -eq 'THROW') {
                throw "Access to the registry key '$Path' is denied."
            }
            $entry = $global:FakeRegistry[$Path]
            $obj = [PSCustomObject]@{}
            if ($entry) {
                foreach ($k in $entry.Keys) { $obj | Add-Member -NotePropertyName $k -NotePropertyValue $entry[$k] }
            }
            return $obj
        }
    }
    AfterAll {
        # Module-qualified proxy, not a bare Remove-Item: removing the
        # function definition does not reliably restore the real Test-Path
        # cmdlet for the rest of the Pester run (verified empirically --
        # see the file header). Microsoft.PowerShell.Management\Test-Path
        # cannot itself be shadowed by a same-named function, so this keeps
        # Test-Path genuinely working for every Describe block that runs
        # after this one, instead of leaving it broken.
        function global:Test-Path { Microsoft.PowerShell.Management\Test-Path @args }
        Remove-Item function:global:Get-ItemProperty -ErrorAction SilentlyContinue
    }
    BeforeEach { $global:FakeRegistry = @{} }

    It "returns null when the hive key does not exist" {
        Get-ConfigPathFromHive -Hive 'HKLM:\SOFTWARE\LegacyMCP' | Should -BeNullOrEmpty
    }

    It "returns null when the hive exists but has no ConfigPath property" {
        $global:FakeRegistry['HKLM:\SOFTWARE\LegacyMCP'] = @{ SomeOtherValue = 'x' }
        Get-ConfigPathFromHive -Hive 'HKLM:\SOFTWARE\LegacyMCP' | Should -BeNullOrEmpty
    }

    It "returns null when ConfigPath is present but empty/whitespace" {
        $global:FakeRegistry['HKLM:\SOFTWARE\LegacyMCP'] = @{ ConfigPath = '   ' }
        Get-ConfigPathFromHive -Hive 'HKLM:\SOFTWARE\LegacyMCP' | Should -BeNullOrEmpty
    }

    It "returns the ConfigPath value when present" {
        $global:FakeRegistry['HKLM:\SOFTWARE\LegacyMCP'] = @{ ConfigPath = 'C:\ProgramData\LegacyMCP\config\config.yaml' }
        Get-ConfigPathFromHive -Hive 'HKLM:\SOFTWARE\LegacyMCP' | Should -Be 'C:\ProgramData\LegacyMCP\config\config.yaml'
    }

    It "propagates an unexpected registry read error instead of swallowing it (P4)" {
        $global:FakeRegistry['HKLM:\SOFTWARE\LegacyMCP'] = 'THROW'
        { Get-ConfigPathFromHive -Hive 'HKLM:\SOFTWARE\LegacyMCP' } | Should -Throw
    }
}

# ---------------------------------------------------------------------------
# Resolve-ConfigPath -- the function with a real production regression
# history (task #125): Manage-Workspaces.ps1 was not updated after the path
# refactoring in sessions #38-40 and silently fell back to a wrong relative
# path on Profile A installs (registry written to HKCU, code only checked
# HKLM). Coverage here targets exactly the scenarios that broke, not just the
# happy path.
# ---------------------------------------------------------------------------
Describe "Resolve-ConfigPath" {
    BeforeAll {
        function global:Test-Path {
            param($Path)
            return $global:FakeRegistry.ContainsKey($Path)
        }
        function global:Get-ItemProperty {
            param($Path, $ErrorAction)
            $entry = $global:FakeRegistry[$Path]
            $obj = [PSCustomObject]@{}
            if ($entry) {
                foreach ($k in $entry.Keys) { $obj | Add-Member -NotePropertyName $k -NotePropertyValue $entry[$k] }
            }
            return $obj
        }
    }
    AfterAll {
        # Module-qualified proxy, not a bare Remove-Item: removing the
        # function definition does not reliably restore the real Test-Path
        # cmdlet for the rest of the Pester run (verified empirically --
        # see the file header). Microsoft.PowerShell.Management\Test-Path
        # cannot itself be shadowed by a same-named function, so this keeps
        # Test-Path genuinely working for every Describe block that runs
        # after this one, instead of leaving it broken.
        function global:Test-Path { Microsoft.PowerShell.Management\Test-Path @args }
        Remove-Item function:global:Get-ItemProperty -ErrorAction SilentlyContinue
    }
    BeforeEach { $global:FakeRegistry = @{} }

    It "bypasses the registry entirely for an explicit absolute -Config path" {
        # $global:FakeRegistry stays empty -- if the function touched the
        # registry at all here, Test-Path/Get-ItemProperty would return
        # falsy/empty and this would fail differently (null or a throw),
        # not silently pass.
        $r = Resolve-ConfigPath -Path 'C:\Custom\config.yaml'
        $r | Should -Be 'C:\Custom\config.yaml'
    }

    It "resolves from HKLM when only HKLM has ConfigPath (Profile B)" {
        $global:FakeRegistry['HKLM:\SOFTWARE\LegacyMCP'] = @{ ConfigPath = 'C:\ProgramData\LegacyMCP\config\config.yaml' }
        Resolve-ConfigPath -Path 'config\config.yaml' | Should -Be 'C:\ProgramData\LegacyMCP\config\config.yaml'
    }

    It "resolves from HKCU when only HKCU has ConfigPath (Profile A -- the #125 regression case)" {
        # This is exactly the scenario that broke in production: Profile A
        # writes ConfigPath under HKCU, and the pre-fix code only checked
        # HKLM, silently falling through to a wrong relative-path guess.
        $global:FakeRegistry['HKCU:\SOFTWARE\LegacyMCP'] = @{ ConfigPath = 'C:\Users\consultant\AppData\Local\LegacyMCP\config\config.yaml' }
        Resolve-ConfigPath -Path 'config\config.yaml' | Should -Be 'C:\Users\consultant\AppData\Local\LegacyMCP\config\config.yaml'
    }

    It "throws an explicit, actionable error when BOTH hives have ConfigPath" {
        $global:FakeRegistry['HKLM:\SOFTWARE\LegacyMCP'] = @{ ConfigPath = 'C:\ProgramData\LegacyMCP\config\config.yaml' }
        $global:FakeRegistry['HKCU:\SOFTWARE\LegacyMCP'] = @{ ConfigPath = 'C:\Users\x\LegacyMCP\config\config.yaml' }
        { Resolve-ConfigPath -Path 'config\config.yaml' } | Should -Throw "*Two LegacyMCP installations*-Config*"
    }

    It "names both conflicting paths in the ambiguous-hive error" {
        $global:FakeRegistry['HKLM:\SOFTWARE\LegacyMCP'] = @{ ConfigPath = 'C:\ProgramData\LegacyMCP\config\config.yaml' }
        $global:FakeRegistry['HKCU:\SOFTWARE\LegacyMCP'] = @{ ConfigPath = 'C:\Users\x\LegacyMCP\config\config.yaml' }
        { Resolve-ConfigPath -Path 'config\config.yaml' } |
            Should -Throw "*C:\ProgramData\LegacyMCP\config\config.yaml*C:\Users\x\LegacyMCP\config\config.yaml*"
    }

    It "throws an explicit, actionable error when NEITHER hive has ConfigPath (no silent guessed fallback -- P4)" {
        { Resolve-ConfigPath -Path 'config\config.yaml' } | Should -Throw "*No LegacyMCP installation found*Setup-LegacyMCP.ps1*"
    }
}

# ---------------------------------------------------------------------------
# ConvertFrom-ForestsText -- built-in fallback YAML parser (used when the
# powershell-yaml module is not installed). Hand-written state machine over
# raw text: the highest-risk logic in this file precisely because it has no
# library backing it.
# ---------------------------------------------------------------------------
Describe "ConvertFrom-ForestsText" {

    It "returns an empty array for text with no workspace block" {
        $r = ConvertFrom-ForestsText -Text "profile: A`n"
        @($r).Count | Should -Be 0
    }

    It "returns an empty array for an empty forests list" {
        $r = ConvertFrom-ForestsText -Text "workspace:`n  forests:`n"
        @($r).Count | Should -Be 0
    }

    It "parses a single forest with inline name and one property" {
        # Plain assignment, not @(...): the fixed function already guarantees
        # a real array via the comma operator. Wrapping the call site in @()
        # would capture the single pipeline object (the array itself) and
        # wrap IT in a second array -- verified empirically while updating
        # this suite after the #127 fix. Production call sites (Get-Forests)
        # never wrap this way either.
        $text = "workspace:`n  forests:`n    - name: contoso.local`n      module: ad-core`n"
        $r = ConvertFrom-ForestsText -Text $text
        $r.Count      | Should -Be 1
        $r[0].name    | Should -Be 'contoso.local'
        $r[0].module  | Should -Be 'ad-core'
    }

    It "parses multiple forests as a real array with correct per-forest fields" {
        $text = "workspace:`n  forests:`n" +
                "    - name: a.local`n      module: ad-core`n      relation: standalone`n" +
                "    - name: b.local`n      dc: dc01.b.local`n"
        $r = ConvertFrom-ForestsText -Text $text
        $r.Count       | Should -Be 2
        $r[0].name     | Should -Be 'a.local'
        $r[0].relation | Should -Be 'standalone'
        $r[1].name     | Should -Be 'b.local'
        $r[1].dc       | Should -Be 'dc01.b.local'
    }

    It "stops parsing once the workspace block ends (0-indent line after it)" {
        $text = "workspace:`n  forests:`n    - name: a.local`n      module: ad-core`n" +
                "server:`n  port: 8000`n"
        $r = ConvertFrom-ForestsText -Text $text
        $r.Count   | Should -Be 1
        $r[0].name | Should -Be 'a.local'
    }

    It "returns a real array (not a bare hashtable) for exactly one forest" {
        # Regression guard, now for the FIXED behavior. Originally this
        # function returned "$forests" without protection: PowerShell's
        # return/output stream enumerates arrays onto the pipeline, so a
        # single-element array collapsed to the bare hashtable at the
        # caller. Fixed with the comma operator ("return ,$forests"), the
        # same technique already used today in Membership.psm1 for the
        # identical problem (Get-RawGroupMemberDNs, task #134) -- plain
        # "@()" around the returned value does NOT survive the pipeline
        # enumeration, it was verified empirically before this fix and does
        # not work.
        #
        # Real call site: Get-Forests (Invoke-List, Invoke-Add,
        # Invoke-Validate, Invoke-RepairMetadata) returns this value
        # directly, so .Count must mean "number of forests", not "number of
        # hashtable keys of the one forest that happened to survive".
        $text = "workspace:`n  forests:`n    - name: solo.local`n      module: ad-core`n"
        $r = ConvertFrom-ForestsText -Text $text
        $r.GetType().Name | Should -Be 'Object[]'
        $r.Count          | Should -Be 1
        $r[0].name        | Should -Be 'solo.local'
    }

    It "returns a real, non-null empty array for zero forests (was a StrictMode crash)" {
        # Separate, more severe pre-existing bug found while fixing the
        # single-forest case above: a bare "return $forests" on an EMPTY
        # array also collapses -- but to $null, not to a bare element.
        # $null.Count throws PropertyNotFoundStrict under
        # Set-StrictMode -Version Latest, which this script has active. A
        # config.yaml with zero forests configured therefore crashed
        # Get-Forests outright (used by every Invoke-* command) instead of
        # showing "no forests configured". Fixed by the same comma-operator
        # change, which preserves array-ness uniformly for 0, 1, and N items.
        $r = ConvertFrom-ForestsText -Text "profile: A`n"
        ($null -eq $r) | Should -BeFalse -Because "a real empty array is a valid object; `$null is not, under StrictMode"
        $r.GetType().Name | Should -Be 'Object[]'
        { $r.Count } | Should -Not -Throw
        $r.Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# Get-Forests -- the real caller of ConvertFrom-ForestsText, used directly by
# Invoke-List, Invoke-Add, Invoke-Validate and Invoke-RepairMetadata. Exists
# as its own Describe block because it is ITSELF a second collapse point: even
# after fixing ConvertFrom-ForestsText, Get-Forests's own "return $forests"
# (and the parallel YAML-module-path returns) could re-collapse the array a
# second time at its own function boundary -- verified empirically before
# fixing, both are now protected with the comma operator.
#
# Read-ConfigRaw is stubbed globally per test (Get-Forests's only external
# dependency besides $script:UseYamlModule) so no real config.yaml is read.
# ---------------------------------------------------------------------------
Describe "Get-Forests" {
    BeforeAll { $script:UseYamlModule = $false }  # exercise the fallback text-parser path
    AfterAll  { Remove-Item function:global:Read-ConfigRaw -ErrorAction SilentlyContinue }

    It "returns a real, non-null empty array when the config has no forests (was a StrictMode crash)" {
        function global:Read-ConfigRaw { return "profile: A`n" }
        { Get-Forests } | Should -Not -Throw
        $r = Get-Forests
        ($null -eq $r)    | Should -BeFalse
        $r.GetType().Name | Should -Be 'Object[]'
        $r.Count          | Should -Be 0
    }

    It "returns a real one-element array for a single configured forest (the reported #127 bug)" {
        function global:Read-ConfigRaw {
            return "workspace:`n  forests:`n    - name: solo.local`n      module: ad-core`n"
        }
        $r = Get-Forests
        $r.GetType().Name | Should -Be 'Object[]'
        $r.Count          | Should -Be 1
        $r[0]['name']     | Should -Be 'solo.local'
    }

    It "keeps returning a correct array for multiple forests (no regression)" {
        function global:Read-ConfigRaw {
            return "workspace:`n  forests:`n" +
                   "    - name: a.local`n      module: ad-core`n" +
                   "    - name: b.local`n      module: ad-core`n"
        }
        $r = Get-Forests
        $r.Count | Should -Be 2
        ($r | ForEach-Object { $_['name'] }) | Should -Be @('a.local', 'b.local')
    }

    It "lets a single-forest result be consumed the way Invoke-List/-Validate/-RepairMetadata do" {
        # These callers do: if ($forests.Count -eq 0) {...} ; foreach ($f in $forests) { $f['name'] }
        # Both must work without throwing and without misreporting the count.
        function global:Read-ConfigRaw {
            return "workspace:`n  forests:`n    - name: solo.local`n      module: ad-core`n"
        }
        $forests = Get-Forests
        $forests.Count | Should -Be 1
        $seen = @()
        foreach ($f in $forests) { $seen += $f['name'] }
        $seen | Should -Be @('solo.local')
    }
}

# ---------------------------------------------------------------------------
# Get-ConfigSections -- splits config.yaml text into Pre/Body/Post around the
# "  forests:" block, so Add-ForestToConfig/Remove-ForestFromConfig can
# rewrite only the Body while preserving everything else verbatim.
# ---------------------------------------------------------------------------
Describe "Get-ConfigSections" {

    It "splits Pre/Body/Post around a populated forests block" {
        $text = "profile: A`n`nworkspace:`n  forests:`n    - name: a.local`n      module: ad-core`n`nserver:`n  port: 8000`n"
        $s = Get-ConfigSections -Text $text
        ($s.Pre -join "`n")  | Should -Match 'profile: A'
        ($s.Pre -join "`n")  | Should -Match 'forests:$'
        ($s.Body -join "`n") | Should -Match 'name: a.local'
        ($s.Post -join "`n") | Should -Match 'port: 8000'
    }

    It "keeps Body empty when the forests block has no entries" {
        $text = "workspace:`n  forests:`nserver:`n  port: 8000`n"
        $s = Get-ConfigSections -Text $text
        (@($s.Body) | Where-Object { $_ -match '\S' }).Count | Should -Be 0
        ($s.Post -join "`n") | Should -Match 'port: 8000'
    }

    It "puts everything in Pre when there is no forests block at all" {
        $text = "profile: A`nserver:`n  port: 8000`n"
        $s = Get-ConfigSections -Text $text
        ($s.Pre -join "`n") | Should -Match 'port: 8000'
        (@($s.Body) | Where-Object { $_ -match '\S' }).Count | Should -Be 0
        (@($s.Post) | Where-Object { $_ -match '\S' }).Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# Format-ForestBlock -- hashtable -> YAML lines for a single forest entry.
# ---------------------------------------------------------------------------
Describe "Format-ForestBlock" {

    It "always emits name first" {
        $lines = Format-ForestBlock -Forest @{ module = 'ad-core'; name = 'contoso.local' }
        $lines[0] | Should -Be '    - name: contoso.local'
    }

    It "emits known keys in the fixed order: relation, module, mode, file, dc, credentials" {
        $lines = Format-ForestBlock -Forest @{
            name = 'contoso.local'; dc = 'dc01.contoso.local'
            module = 'ad-core'; relation = 'standalone'
        }
        $lines | Should -Be @(
            '    - name: contoso.local',
            '      relation: standalone',
            '      module: ad-core',
            '      dc: dc01.contoso.local'
        )
    }

    It "appends unknown keys after the ordered ones" {
        $lines = Format-ForestBlock -Forest @{ name = 'x.local'; custom_field = 'zzz' }
        $lines[-1] | Should -Be '      custom_field: zzz'
    }

    It "skips keys with falsy/empty values" {
        $lines = Format-ForestBlock -Forest @{ name = 'x.local'; module = 'ad-core'; file = '' }
        ($lines -join "`n") | Should -Not -Match 'file:'
    }
}

# ---------------------------------------------------------------------------
# Remove-ForestFromConfig -- the text-surgery Invoke-Remove depends on (task
# #127, Fase 2 tranche 2): finds the "    - name: <X>" line, then the line
# range up to (but not including) the next "    - " entry or the first line
# with <4-space indent, and deletes that range. Exactly the off-by-one
# line-range bug class already found twice in this file (Get-Forests/#127,
# Get-RawGroupMemberDNs/#134), so coverage here is on precise byte-level
# survival of the OTHER forests, not just "the target is gone".
#
# Isolated AST extraction, its OWN parse and Invoke-Expression -- NOT part
# of the shared pool at the top of this file. See the file header note:
# mixing this into the shared pool would make the global:Read-ConfigRaw/
# global:Write-ConfigRaw stubs below silently ineffective, because
# Remove-ForestFromConfig's own Read-ConfigRaw/Write-ConfigRaw calls would
# resolve to whatever was extracted alongside it in that shared scope
# instead, if anything ever were.
# ---------------------------------------------------------------------------
Describe "Remove-ForestFromConfig" {
    BeforeAll {
        $sourcePath = (Resolve-Path (Join-Path $PSScriptRoot "..\..\installer\Manage-Workspaces.ps1")).Path
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw "Failed to parse Manage-Workspaces.ps1: $($parseErrors -join '; ')"
        }
        $funcAst = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Remove-ForestFromConfig'
        }, $true)
        if ($funcAst.Count -ne 1) {
            throw "Expected exactly one Remove-ForestFromConfig definition, found $($funcAst.Count)"
        }
        Invoke-Expression $funcAst[0].Extent.Text
    }

    AfterAll {
        Remove-Item function:global:Read-ConfigRaw  -ErrorAction SilentlyContinue
        Remove-Item function:global:Write-ConfigRaw -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:CapturedWrite = $null
        function global:Write-ConfigRaw {
            param([string]$Content)
            $script:CapturedWrite = $Content
        }
    }

    It "removes the only forest, does not throw, and writes the emptied block" {
        function global:Read-ConfigRaw {
            return "workspace:`n  forests:`n    - name: solo.local`n      module: ad-core`n"
        }
        $result = Remove-ForestFromConfig -ForestName 'solo.local'
        $result | Should -BeTrue
        $script:CapturedWrite | Should -Not -Match 'name: solo\.local'
        $script:CapturedWrite | Should -Match 'workspace:'
        $script:CapturedWrite | Should -Match 'forests:'
    }

    It "removes the middle forest of three, leaving the other two byte-correct" {
        function global:Read-ConfigRaw {
            return "workspace:`n  forests:`n" +
                   "    - name: alpha.local`n      module: ad-core`n      relation: standalone`n" +
                   "    - name: beta.local`n      module: ad-core`n      dc: dc01.beta.local`n" +
                   "    - name: gamma.local`n      module: ad-core`n      relation: standalone`n"
        }
        $result = Remove-ForestFromConfig -ForestName 'beta.local'
        $result | Should -BeTrue
        $script:CapturedWrite | Should -Not -Match 'name: beta\.local'
        $script:CapturedWrite | Should -Not -Match 'dc: dc01\.beta\.local'
        $script:CapturedWrite | Should -Match 'name: alpha\.local'
        $script:CapturedWrite | Should -Match 'relation: standalone'
        $script:CapturedWrite | Should -Match 'name: gamma\.local'
        # Both survivors' relation: standalone lines must both still be
        # present -- a count check catches a range that ate one of them.
        ([regex]::Matches($script:CapturedWrite, 'relation: standalone')).Count | Should -Be 2
    }

    It "removes the first forest of three without corrupting the remaining two" {
        function global:Read-ConfigRaw {
            return "workspace:`n  forests:`n" +
                   "    - name: alpha.local`n      module: ad-core`n" +
                   "    - name: beta.local`n      module: ad-core`n" +
                   "    - name: gamma.local`n      module: ad-core`n"
        }
        $result = Remove-ForestFromConfig -ForestName 'alpha.local'
        $result | Should -BeTrue
        $script:CapturedWrite | Should -Not -Match 'name: alpha\.local'
        $script:CapturedWrite | Should -Match 'name: beta\.local'
        $script:CapturedWrite | Should -Match 'name: gamma\.local'
    }

    It "removes the last forest of three without corrupting the remaining two (endIdx = lines.Count boundary)" {
        function global:Read-ConfigRaw {
            return "workspace:`n  forests:`n" +
                   "    - name: alpha.local`n      module: ad-core`n" +
                   "    - name: beta.local`n      module: ad-core`n" +
                   "    - name: gamma.local`n      module: ad-core`n"
        }
        $result = Remove-ForestFromConfig -ForestName 'gamma.local'
        $result | Should -BeTrue
        $script:CapturedWrite | Should -Not -Match 'name: gamma\.local'
        $script:CapturedWrite | Should -Match 'name: alpha\.local'
        $script:CapturedWrite | Should -Match 'name: beta\.local'
    }

    It "returns `$false and does NOT write anything when the forest name is not found" {
        function global:Read-ConfigRaw {
            return "workspace:`n  forests:`n    - name: alpha.local`n      module: ad-core`n"
        }
        $result = Remove-ForestFromConfig -ForestName 'ghost.local'
        $result | Should -BeFalse
        $script:CapturedWrite | Should -BeNullOrEmpty -Because "Write-ConfigRaw must never be called when nothing was found to remove"
    }

    It "escapes the forest name as a regex literal -- a dotted name does not accidentally match an unrelated similar name" {
        # Without [regex]::Escape, the pattern for 'contoso.local' would
        # read the '.' as "any character", which also matches the line for
        # 'contosoXlocal' (same length, X where the literal dot is). This
        # is the real risk this test protects against, not a contrived one.
        function global:Read-ConfigRaw {
            return "workspace:`n  forests:`n" +
                   "    - name: contoso.local`n      module: ad-core`n" +
                   "    - name: contosoXlocal`n      module: ad-core`n"
        }
        $result = Remove-ForestFromConfig -ForestName 'contoso.local'
        $result | Should -BeTrue
        $script:CapturedWrite | Should -Not -Match 'name: contoso\.local'
        $script:CapturedWrite | Should -Match 'name: contosoXlocal'
    }
}

# ---------------------------------------------------------------------------
# Get-JsonProperty -- StrictMode-safe property accessor for parsed JSON
# (PSCustomObject from ConvertFrom-Json), used because _metadata is absent
# from JSON files produced by collector versions older than 1.5.
# ---------------------------------------------------------------------------
Describe "Get-JsonProperty" {

    It "returns null for a null object without throwing under StrictMode" {
        { Get-JsonProperty -Obj $null -Name 'forest' } | Should -Not -Throw
        Get-JsonProperty -Obj $null -Name 'forest' | Should -BeNullOrEmpty
    }

    It "returns null when the property is absent instead of throwing PropertyNotFoundStrict" {
        $obj = [PSCustomObject]@{ users = @() }
        { Get-JsonProperty -Obj $obj -Name '_metadata' } | Should -Not -Throw
        Get-JsonProperty -Obj $obj -Name '_metadata' | Should -BeNullOrEmpty
    }

    It "returns the value when the property is present" {
        $obj = [PSCustomObject]@{ _metadata = @{ forest = 'contoso.local' } }
        (Get-JsonProperty -Obj $obj -Name '_metadata').forest | Should -Be 'contoso.local'
    }
}

# ---------------------------------------------------------------------------
# Resolve-Module -- infers the collector module type ('ad-core'/'unknown')
# from the JSON's top-level key shape, used by Invoke-Add to auto-detect
# -Module when adding an offline forest from a JSON file.
# ---------------------------------------------------------------------------
Describe "Resolve-Module" {

    It "returns 'ad-core' when at least 3 of the ad-core marker keys are present" {
        $obj = [PSCustomObject]@{ forest = @{}; dcs = @(); domains = @(); unrelated = 1 }
        Resolve-Module -JsonData $obj | Should -Be 'ad-core'
    }

    It "returns 'unknown' when fewer than 3 marker keys are present (boundary: exactly 2)" {
        $obj = [PSCustomObject]@{ forest = @{}; dcs = @(); unrelated = 1 }
        Resolve-Module -JsonData $obj | Should -Be 'unknown'
    }

    It "returns 'unknown' for an unrelated JSON shape" {
        $obj = [PSCustomObject]@{ foo = 1; bar = 2 }
        Resolve-Module -JsonData $obj | Should -Be 'unknown'
    }
}

# ---------------------------------------------------------------------------
# Read-JsonFile / Write-JsonFile (task #127, Fase 2 tranche 2). Genuinely
# pure on their explicit -Path/-Data parameters -- neither calls any other
# function defined in Manage-Workspaces.ps1, so they are in the shared
# extraction pool at the top of this file (see header note) and tested here
# against REAL temp files, not stubs. The BOM handling is the point: it
# ties directly to a documented historical bug (getting-started-a.md's
# troubleshooting section covers the collector producing UTF-8-with-BOM
# JSON that older loaders mishandled).
# ---------------------------------------------------------------------------
Describe "Read-JsonFile / Write-JsonFile" {
    BeforeAll {
        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("lmcp-json-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
    }
    AfterAll {
        if ($script:WorkDir -and [System.IO.Directory]::Exists($script:WorkDir)) {
            Remove-Item $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reads a plain UTF-8 file without BOM correctly" {
        $path = Join-Path $script:WorkDir "no-bom.json"
        [System.IO.File]::WriteAllText($path, '{"forest":"contoso.local","count":3}', [System.Text.UTF8Encoding]::new($false))
        $data = Read-JsonFile -Path $path
        $data.forest | Should -Be 'contoso.local'
        $data.count  | Should -Be 3
    }

    It "reads a UTF-8 file WITH a BOM correctly (strips it instead of choking on it)" {
        $path = Join-Path $script:WorkDir "with-bom.json"
        # UTF8Encoding($true) emits the BOM -- the exact shape a collector
        # run predating the loader's BOM fix could still produce.
        [System.IO.File]::WriteAllText($path, '{"forest":"fabrikam.local"}', [System.Text.UTF8Encoding]::new($true))
        $bytes = [System.IO.File]::ReadAllBytes($path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue -Because "the fixture itself must actually have a BOM for this test to mean anything"
        { Read-JsonFile -Path $path } | Should -Not -Throw
        (Read-JsonFile -Path $path).forest | Should -Be 'fabrikam.local'
    }

    It "Write-JsonFile writes valid UTF-8 WITHOUT a BOM (P11)" {
        $path = Join-Path $script:WorkDir "written.json"
        Write-JsonFile -Path $path -Data ([PSCustomObject]@{ forest = 'contoso.local' })
        $bytes = [System.IO.File]::ReadAllBytes($path)
        # A BOM would be exactly EF BB BF as the first three bytes.
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }

    It "round-trips a nested object through Write-JsonFile then Read-JsonFile" {
        $path = Join-Path $script:WorkDir "roundtrip.json"
        $original = [PSCustomObject]@{
            forest = 'contoso.local'
            users  = @(
                [PSCustomObject]@{ name = 'a.rossi'; groups = @('Domain Admins', 'IT-Helpdesk') }
                [PSCustomObject]@{ name = 'm.ferrari'; groups = @() }
            )
        }
        Write-JsonFile -Path $path -Data $original
        $roundtripped = Read-JsonFile -Path $path
        $roundtripped.forest              | Should -Be 'contoso.local'
        $roundtripped.users.Count         | Should -Be 2
        $roundtripped.users[0].name       | Should -Be 'a.rossi'
        $roundtripped.users[0].groups     | Should -Be @('Domain Admins', 'IT-Helpdesk')
        $roundtripped.users[1].groups.Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# Backup-JsonFile (task #127, Fase 2 tranche 2). Used by Invoke-RepairMetadata
# right before it overwrites a JSON file -- the only thing standing between
# a repair attempt and permanent data loss if something goes wrong mid-write.
#
# In the shared extraction pool (see file header), but its own body calls
# Test-Path internally to decide whether to create backups\. Same defensive
# module-qualified proxy as the Read-ConfigRaw/Write-ConfigRaw block above,
# for the same reason -- this function is called from within an It block
# here, which can run after Get-ConfigPathFromHive/Resolve-ConfigPath have
# already left the global Test-Path broken.
# ---------------------------------------------------------------------------
Describe "Backup-JsonFile" {
    BeforeAll {
        function global:Test-Path { Microsoft.PowerShell.Management\Test-Path @args }

        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("lmcp-backup-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
    }
    AfterAll {
        Remove-Item function:global:Test-Path -ErrorAction SilentlyContinue
        if ($script:WorkDir -and [System.IO.Directory]::Exists($script:WorkDir)) {
            Remove-Item $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "creates the backups\ directory when it does not exist yet" {
        $src = Join-Path $script:WorkDir "contoso.local.json"
        Set-Content -Path $src -Encoding UTF8 -Value '{"users":[]}'
        $backupsDir = Join-Path $script:WorkDir "backups"
        [System.IO.Directory]::Exists($backupsDir) | Should -BeFalse
        Backup-JsonFile -Path $src | Out-Null
        [System.IO.Directory]::Exists($backupsDir) | Should -BeTrue
    }

    It "copies the file into backups\ with a timestamp-suffixed name and returns that path" {
        $src = Join-Path $script:WorkDir "fabrikam.local.json"
        Set-Content -Path $src -Encoding UTF8 -Value '{"users":["a"]}'
        $dest = Backup-JsonFile -Path $src
        [System.IO.File]::Exists($dest) | Should -BeTrue
        (Split-Path $dest -Leaf) | Should -Match '^fabrikam\.local_\d{8}-\d{6}\.json$'
        [System.IO.File]::ReadAllText($dest) | Should -Be ([System.IO.File]::ReadAllText($src))
    }

    It "leaves the original file untouched" {
        $src = Join-Path $script:WorkDir "untouched.local.json"
        $content = '{"users":["preserve-me"]}'
        [System.IO.File]::WriteAllText($src, $content, [System.Text.UTF8Encoding]::new($false))
        Backup-JsonFile -Path $src | Out-Null
        [System.IO.File]::ReadAllText($src) | Should -Be $content
    }

    It "does not error when backups\ already exists from a previous call" {
        $src = Join-Path $script:WorkDir "twice.local.json"
        Set-Content -Path $src -Encoding UTF8 -Value '{"users":[]}'
        { Backup-JsonFile -Path $src } | Should -Not -Throw
        { Backup-JsonFile -Path $src } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# Test-DcReachable (task #127, Fase 2 tranche 2). Thin wrapper around
# Test-NetConnection, used by Invoke-Add/Invoke-Validate to flag (not
# block) an unreachable DC for a live-mode forest. Lowest priority of the
# 8 in the approved plan -- the only real logic here is the try/catch
# fallback, and actual WinRM reachability is an integration concern
# already covered by the field-test protocol (P17), not a unit-test one.
#
# Test-NetConnection is stubbed globally, same technique as
# Get-ConfigPathFromHive's Test-Path/Get-ItemProperty stubs earlier in this
# file -- safe here because Test-NetConnection is an external cmdlet never
# redefined anywhere in Manage-Workspaces.ps1 or in this shared extraction
# pool (same reasoning that makes that existing pattern work, verified
# empirically not to apply when the target IS separately extracted -- see
# the Read-ConfigRaw/Remove-ForestFromConfig isolation note in the file
# header).
# ---------------------------------------------------------------------------
Describe "Test-DcReachable" {
    AfterEach {
        Remove-Item function:global:Test-NetConnection -ErrorAction SilentlyContinue
    }

    It "returns `$true when Test-NetConnection reports the DC reachable" {
        function global:Test-NetConnection { return $true }
        Test-DcReachable -DCHost 'dc01.contoso.local' | Should -BeTrue
    }

    It "returns `$false when Test-NetConnection reports the DC unreachable" {
        function global:Test-NetConnection { return $false }
        Test-DcReachable -DCHost 'dc01.contoso.local' | Should -BeFalse
    }

    It "returns `$false instead of throwing when Test-NetConnection itself throws" {
        function global:Test-NetConnection { throw "WinRM probe failed unexpectedly" }
        { Test-DcReachable -DCHost 'dc01.contoso.local' } | Should -Not -Throw
        Test-DcReachable -DCHost 'dc01.contoso.local' | Should -BeFalse
    }
}

# ---------------------------------------------------------------------------
# Read-ConfigRaw / Write-ConfigRaw (task #127, Fase 2 tranche 2). The
# config.yaml counterpart of Read-JsonFile/Write-JsonFile above -- same BOM
# risk (P11: UTF-8 without BOM, always), but every single CRUD operation in
# this script funnels through these two.
#
# Isolated AST extraction, own parse and Invoke-Expression -- NOT the shared
# pool. See the file header note: these reference $ConfigFile (a script
# variable set at the TOP LEVEL of the real script, never part of any
# extraction), so it is set explicitly here to a real temp file before each
# call. Kept isolated so nothing here can ever collide with Get-Forests's
# global:Read-ConfigRaw stub in a different Describe block.
#
# Second, DIFFERENT consequence of the same Test-Path leak documented in the
# file header: Read-ConfigRaw's own body calls Test-Path internally. Found
# empirically while writing this block -- it passed running in isolation
# (Get-ConfigPathFromHive/Resolve-ConfigPath never ran, so nothing was ever
# stubbed) but failed running as part of the full suite ("config.yaml not
# found" on a file that demonstrably existed), because by then Test-Path
# unconditionally returns $false for everyone, including the real
# Read-ConfigRaw's own internal check. Defensively re-established below via
# a module-qualified proxy (Microsoft.PowerShell.Management\Test-Path),
# which cannot itself be shadowed by a same-named function -- this makes
# the block correct regardless of what ran before it, instead of depending
# on fixing the leak at its source (out of scope for this tranche).
# ---------------------------------------------------------------------------
Describe "Read-ConfigRaw / Write-ConfigRaw" {
    BeforeAll {
        function global:Test-Path { Microsoft.PowerShell.Management\Test-Path @args }

        $sourcePath = (Resolve-Path (Join-Path $PSScriptRoot "..\..\installer\Manage-Workspaces.ps1")).Path
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw "Failed to parse Manage-Workspaces.ps1: $($parseErrors -join '; ')"
        }
        $targetFunctions = @('Read-ConfigRaw', 'Write-ConfigRaw')
        $funcAsts = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $targetFunctions -contains $node.Name
        }, $true)
        if ($funcAsts.Count -ne $targetFunctions.Count) {
            throw "Expected 2 function definitions (Read-ConfigRaw, Write-ConfigRaw), found $($funcAsts.Count)"
        }
        $extracted = ($funcAsts | ForEach-Object { $_.Extent.Text }) -join "`n`n"
        Invoke-Expression $extracted

        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("lmcp-configraw-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
    }
    AfterAll {
        Remove-Item function:global:Test-Path -ErrorAction SilentlyContinue
        if ($script:WorkDir -and [System.IO.Directory]::Exists($script:WorkDir)) {
            Remove-Item $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "throws an explicit error when the config file does not exist" {
        $script:ConfigFile = Join-Path $script:WorkDir "does-not-exist.yaml"
        { Read-ConfigRaw } | Should -Throw "*config.yaml not found*"
    }

    It "reads real UTF-8 content correctly" {
        $script:ConfigFile = Join-Path $script:WorkDir "real.yaml"
        [System.IO.File]::WriteAllText($script:ConfigFile, "profile: A`n`nworkspace:`n  forests: []`n", [System.Text.UTF8Encoding]::new($false))
        Read-ConfigRaw | Should -Match "profile: A"
    }

    It "Write-ConfigRaw writes valid UTF-8 WITHOUT a BOM (P11)" {
        $script:ConfigFile = Join-Path $script:WorkDir "written.yaml"
        Write-ConfigRaw -Content "profile: A`n`nworkspace:`n  forests: []`n"
        $bytes = [System.IO.File]::ReadAllBytes($script:ConfigFile)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }

    It "round-trips exact content through Write-ConfigRaw then Read-ConfigRaw" {
        $script:ConfigFile = Join-Path $script:WorkDir "roundtrip.yaml"
        $content = "profile: B-core`n`nworkspace:`n  forests:`n    - name: contoso.local`n      module: ad-core`n      dc: dc01.contoso.local`n"
        Write-ConfigRaw -Content $content
        Read-ConfigRaw | Should -Be $content
    }
}

# ---------------------------------------------------------------------------
# Invoke-RepairMetadata -- zero-forest field-test gap (found manually by
# Marco on 2026-08-09, NOT caught by the suite above). Invoke-RepairMetadata
# is not one of the 8 functions extracted at the top of this file -- it has
# its own top-level `exit` calls, which would terminate the PESTER PROCESS
# itself if invoked in-process (same reason the whole script can't be
# dot-sourced, see file header). It is therefore exercised as a real child
# process instead, the same technique used in CollectorLogScope.Tests.ps1.
#
# Root cause here is DIFFERENT from yesterday's Get-Forests/ConvertFrom-
# ForestsText fix, verified empirically before writing this test (not
# assumed identical, per Marco's explicit instruction):
#   $r = @() | Where-Object { $true }   # $r is $null, NOT an empty array
#   $r = @(@() | Where-Object { $true }) # $r is a real empty array, Count=0
# Get-Forests itself already returns a real (comma-protected) empty array
# for zero forests -- but Invoke-RepairMetadata re-pipes that array through
# Where-Object twice (once for -Name filtering, once for the offline/file
# filter) without re-wrapping in @(), so the pipeline's own zero-output
# behavior collapses it back to $null before the .Count check. -List and
# -Validate (without -Name) never hit this because they either check
# .Count directly on Get-Forests's own result (-List) or only reach a
# bare `foreach` on the unfiltered result (-Validate without -Name) --
# foreach on $null is a silent no-op, .Count on $null is not.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Invoke-List -- daily-use CRUD entry point, the read-only one (task #127,
# Fase 2 tranche 2). Has its own `exit 1` (config.yaml not found), so same
# child-process technique as the rest of the Invoke-* blocks in this file.
#
# No network call anywhere in this function -- verified directly in the
# source: for a live-mode forest it prints "OK (live -- not verified)"
# without ever calling Test-DcReachable. Unlike Invoke-Add, there is no
# -DC branch to exclude here.
# ---------------------------------------------------------------------------
Describe "Invoke-List (child process)" {
    BeforeAll {
        $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..\installer\Manage-Workspaces.ps1")).Path
        $script:WorkDir    = Join-Path ([System.IO.Path]::GetTempPath()) ("lmcp-list-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

        $script:ValidJson = Join-Path $script:WorkDir "valid.json"
        Set-Content -Path $script:ValidJson -Encoding UTF8 -Value '{"_metadata":{"forest":"contoso.local","collected_at":"2026-08-01T00:00:00Z"},"users":[]}'

        $script:NoMetadataJson = Join-Path $script:WorkDir "no-metadata.json"
        Set-Content -Path $script:NoMetadataJson -Encoding UTF8 -Value '{"users":[]}'

        # _metadata present but its own 'forest' field absent -- distinct
        # WARN branch from "no _metadata at all".
        $script:IncompleteMetaJson = Join-Path $script:WorkDir "incomplete-metadata.json"
        Set-Content -Path $script:IncompleteMetaJson -Encoding UTF8 -Value '{"_metadata":{"collected_at":"2026-08-01T00:00:00Z"},"users":[]}'

        $script:MalformedJson = Join-Path $script:WorkDir "malformed.json"
        Set-Content -Path $script:MalformedJson -Encoding UTF8 -Value '{not valid json'

        function global:Invoke-ListChild {
            param([string]$ConfigPath)
            $psExe = "powershell.exe"
            $argList = @(
                "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", $script:ScriptPath,
                "-List", "-Config", $ConfigPath
            )
            $out = & $psExe @argList 2>&1
            return [PSCustomObject]@{
                Output   = ($out | Out-String)
                ExitCode = $LASTEXITCODE
            }
        }

        function global:New-IsolatedConfig {
            param([string]$Content)
            $path = Join-Path $script:WorkDir ("config." + [guid]::NewGuid().ToString("N") + ".yaml")
            Set-Content -Path $path -Encoding UTF8 -Value $Content
            return $path
        }
    }

    AfterAll {
        if ($script:WorkDir -and [System.IO.Directory]::Exists($script:WorkDir)) {
            Remove-Item $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item function:global:Invoke-ListChild -ErrorAction SilentlyContinue
        Remove-Item function:global:New-IsolatedConfig -ErrorAction SilentlyContinue
    }

    It "exits 1 with an explicit error when config.yaml does not exist" {
        $r = Invoke-ListChild -ConfigPath (Join-Path $script:WorkDir "does-not-exist.yaml")
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "config\.yaml not found"
    }

    It "reports '(no forests configured)' for a zero-forest config, exit 0" {
        $cfg = New-IsolatedConfig -Content "profile: A`n`nworkspace:`n  forests: []`n"
        $r = Invoke-ListChild -ConfigPath $cfg
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "no forests configured"
    }

    It "shows OK for an offline forest whose file exists with matching _metadata" {
        $cfg = New-IsolatedConfig -Content (
            "profile: A`n`nworkspace:`n  forests:`n    - name: contoso.local`n      module: ad-core`n      file: $($script:ValidJson.Replace('\','/'))`n"
        )
        $r = Invoke-ListChild -ConfigPath $cfg
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "contoso\.local"
        $r.Output | Should -Match "OK"
        $r.Output | Should -Not -Match "ERROR"
    }

    It "warns when the JSON has no _metadata block at all" {
        $cfg = New-IsolatedConfig -Content (
            "profile: A`n`nworkspace:`n  forests:`n    - name: nometa.local`n      module: ad-core`n      file: $($script:NoMetadataJson.Replace('\','/'))`n"
        )
        $r = Invoke-ListChild -ConfigPath $cfg
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "WARN.*_metadata missing"
    }

    It "warns with a DIFFERENT message when _metadata is present but incomplete" {
        $cfg = New-IsolatedConfig -Content (
            "profile: A`n`nworkspace:`n  forests:`n    - name: incomplete.local`n      module: ad-core`n      file: $($script:IncompleteMetaJson.Replace('\','/'))`n"
        )
        $r = Invoke-ListChild -ConfigPath $cfg
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "WARN.*_metadata incomplete"
    }

    It "reports ERROR when the offline forest's file does not exist on disk" {
        $cfg = New-IsolatedConfig -Content (
            "profile: A`n`nworkspace:`n  forests:`n    - name: missing.local`n      module: ad-core`n      file: C:/nowhere/missing.json`n"
        )
        $r = Invoke-ListChild -ConfigPath $cfg
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "ERROR.*file not found"
    }

    It "warns when the JSON file exists but fails to parse" {
        $cfg = New-IsolatedConfig -Content (
            "profile: A`n`nworkspace:`n  forests:`n    - name: broken.local`n      module: ad-core`n      file: $($script:MalformedJson.Replace('\','/'))`n"
        )
        $r = Invoke-ListChild -ConfigPath $cfg
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "WARN.*JSON not readable"
    }

    It "shows OK (live -- not verified) for a live-mode forest, no network call needed" {
        $cfg = New-IsolatedConfig -Content (
            "profile: B-core`n`nworkspace:`n  forests:`n    - name: live.local`n      module: ad-core`n      dc: dc01.ghost.local`n      mode: live`n"
        )
        $r = Invoke-ListChild -ConfigPath $cfg
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "live\.local"
        $r.Output | Should -Match "not verified"
    }

    It "lists multiple forests with independently correct status per row" {
        $cfg = New-IsolatedConfig -Content (
            "profile: A`n`nworkspace:`n  forests:`n" +
            "    - name: good.local`n      module: ad-core`n      file: $($script:ValidJson.Replace('\','/'))`n" +
            "    - name: bad.local`n      module: ad-core`n      file: C:/nowhere/bad.json`n"
        )
        $r = Invoke-ListChild -ConfigPath $cfg
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "good\.local"
        $r.Output | Should -Match "bad\.local"
        $r.Output | Should -Match "ERROR.*file not found"
    }
}

# ---------------------------------------------------------------------------
# Invoke-Add -- daily-use CRUD entry point (task #127, Fase 2 tranche 2).
# Not one of the extracted functions above: it has 5 of its own `exit` calls
# (same reason the whole script can't be dot-sourced, see file header), so
# it is exercised as a real child process, same technique as
# Invoke-RepairMetadata/Invoke-Validate below.
#
# The -DC (live mode) success path is deliberately NOT covered here: it
# calls Test-DcReachable, which does a real Test-NetConnection network
# probe. Confirmed out of scope in the Fase 1 plan Marco approved, same
# reasoning already applied to registry/DPAPI/NSSM/ACL AD/WinForms -- a
# real network dependency in the unit suite for marginal added coverage.
# The -File/-DC argument-validation branches below (missing both, both
# provided) never reach Test-DcReachable at all, so they ARE covered.
#
# All warning-path scenarios use -Force. Read-Host's interactive y/N branch
# is not covered, consistent with the rest of this suite -- the existing
# Invoke-RepairMetadata tests never exercise ITS interactive prompts either
# (the zero-forest scenario they cover exits before reaching one). Piping
# fake stdin into a child process to answer the prompt was considered and
# rejected: it would test PowerShell's console host, not this script's
# logic, for a branch this suite already treats as out of reach.
# ---------------------------------------------------------------------------
Describe "Invoke-Add (child process)" {
    BeforeAll {
        $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..\installer\Manage-Workspaces.ps1")).Path
        $script:WorkDir    = Join-Path ([System.IO.Path]::GetTempPath()) ("lmcp-add-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

        # Base config: one existing forest, used for the duplicate-name test
        # and as the "must stay unchanged" baseline for every failure scenario.
        $script:ConfigWithExisting = Join-Path $script:WorkDir "config.existing.yaml"
        Set-Content -Path $script:ConfigWithExisting -Encoding UTF8 -Value @'
profile: A

workspace:
  forests:
    - name: contoso.local
      module: ad-core
      file: C:/existing/contoso.local.json
'@

        # Valid JSON with _metadata.forest matching the -Name used in the
        # success-path tests below.
        $script:ValidJson = Join-Path $script:WorkDir "valid.json"
        Set-Content -Path $script:ValidJson -Encoding UTF8 -Value '{"_metadata":{"forest":"fabrikam.local","collected_at":"2026-08-01T00:00:00Z"},"users":[]}'

        # Same content, no _metadata block at all -- triggers the warning path.
        $script:NoMetadataJson = Join-Path $script:WorkDir "no-metadata.json"
        Set-Content -Path $script:NoMetadataJson -Encoding UTF8 -Value '{"users":[]}'

        function global:Invoke-AddChild {
            param(
                [string]$ConfigPath,
                [string]$NameArg,
                [string]$FileArg,
                [string]$DCArg,
                [switch]$BothFileAndDC,
                [switch]$Force
            )
            $psExe = "powershell.exe"
            $argList = @(
                "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", $script:ScriptPath,
                "-Add", "-Config", $ConfigPath
            )
            if ($NameArg) { $argList += @("-Name", $NameArg) }
            if ($FileArg) { $argList += @("-File", $FileArg) }
            if ($DCArg -or $BothFileAndDC) { $argList += @("-DC", $(if ($DCArg) { $DCArg } else { "dc01.ghost.local" })) }
            if ($Force) { $argList += "-Force" }
            $out = & $psExe @argList 2>&1
            return [PSCustomObject]@{
                Output   = ($out | Out-String)
                ExitCode = $LASTEXITCODE
            }
        }

        # Fresh, isolated copy of a base config for tests that write to it --
        # never share a single file across successful-add tests, or one test's
        # write would leak into the next.
        function global:New-IsolatedConfig {
            param([string]$Content = "profile: A`n`nworkspace:`n  forests: []`n")
            $path = Join-Path $script:WorkDir ("config." + [guid]::NewGuid().ToString("N") + ".yaml")
            Set-Content -Path $path -Encoding UTF8 -Value $Content
            return $path
        }
    }

    AfterAll {
        # [System.IO.Directory]::Exists(), not Test-Path -- see the file
        # header note on the Test-Path stub leak from Get-ConfigPathFromHive/
        # Resolve-ConfigPath (verified empirically: Remove-Item on the
        # global stub function does not restore the real cmdlet for the
        # rest of the run, so a bare Test-Path here would always be $false
        # and silently skip cleanup).
        if ($script:WorkDir -and [System.IO.Directory]::Exists($script:WorkDir)) {
            Remove-Item $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item function:global:Invoke-AddChild -ErrorAction SilentlyContinue
        Remove-Item function:global:New-IsolatedConfig -ErrorAction SilentlyContinue
    }

    It "requires -Name: exits 1 with an explicit error, config.yaml untouched" {
        $before = [System.IO.File]::ReadAllText($script:ConfigWithExisting)
        $r = Invoke-AddChild -ConfigPath $script:ConfigWithExisting -FileArg $script:ValidJson
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "-Name is required"
        [System.IO.File]::ReadAllText($script:ConfigWithExisting) | Should -Be $before
    }

    It "requires -File or -DC: exits 1 when neither is given" {
        $before = [System.IO.File]::ReadAllText($script:ConfigWithExisting)
        $r = Invoke-AddChild -ConfigPath $script:ConfigWithExisting -NameArg "newforest.local"
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "Provide -File.*or -DC"
        [System.IO.File]::ReadAllText($script:ConfigWithExisting) | Should -Be $before
    }

    It "rejects -File and -DC together: exits 1" {
        $before = [System.IO.File]::ReadAllText($script:ConfigWithExisting)
        $r = Invoke-AddChild -ConfigPath $script:ConfigWithExisting -NameArg "newforest.local" -FileArg $script:ValidJson -BothFileAndDC
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "not both"
        [System.IO.File]::ReadAllText($script:ConfigWithExisting) | Should -Be $before
    }

    It "rejects a duplicate forest name: exits 1, config.yaml untouched" {
        $before = [System.IO.File]::ReadAllText($script:ConfigWithExisting)
        $r = Invoke-AddChild -ConfigPath $script:ConfigWithExisting -NameArg "contoso.local" -FileArg $script:ValidJson
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "already exists"
        [System.IO.File]::ReadAllText($script:ConfigWithExisting) | Should -Be $before
    }

    It "fails validation when the JSON file does not exist: exits 1, config.yaml untouched" {
        $cfg = New-IsolatedConfig
        $before = [System.IO.File]::ReadAllText($cfg)
        $r = Invoke-AddChild -ConfigPath $cfg -NameArg "ghost.local" -FileArg (Join-Path $script:WorkDir "does-not-exist.json")
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "Validation failed"
        [System.IO.File]::ReadAllText($cfg) | Should -Be $before
    }

    It "adds a valid forest: exits 0, config.yaml actually contains the new block" {
        $cfg = New-IsolatedConfig
        $r = Invoke-AddChild -ConfigPath $cfg -NameArg "fabrikam.local" -FileArg $script:ValidJson
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "added to workspace"
        $after = [System.IO.File]::ReadAllText($cfg)
        $after | Should -Match "name: fabrikam\.local"
    }

    It "normalizes a backslash Windows path to forward slashes in config.yaml (MW-B)" {
        $cfg = New-IsolatedConfig
        $backslashPath = $script:ValidJson  # already an absolute Windows path with backslashes
        $r = Invoke-AddChild -ConfigPath $cfg -NameArg "fabrikam.local" -FileArg $backslashPath
        $r.ExitCode | Should -Be 0
        $after = [System.IO.File]::ReadAllText($cfg)
        # The written file: line must use forward slashes, matching $backslashPath
        # with '\' replaced by '/' -- and must NOT contain a literal backslash.
        $expectedForward = $backslashPath.Replace('\', '/')
        $after | Should -Match ([regex]::Escape("file: $expectedForward"))
        $after | Should -Not -Match ([regex]::Escape($backslashPath))
    }

    It "does not write a mode: field when the config profile is A" {
        $cfg = New-IsolatedConfig -Content "profile: A`n`nworkspace:`n  forests: []`n"
        $r = Invoke-AddChild -ConfigPath $cfg -NameArg "fabrikam.local" -FileArg $script:ValidJson
        $r.ExitCode | Should -Be 0
        $after = [System.IO.File]::ReadAllText($cfg)
        $after | Should -Not -Match "mode:"
    }

    It "writes mode: offline when the config profile is NOT A (e.g. B-core)" {
        $cfg = New-IsolatedConfig -Content "profile: B-core`n`nworkspace:`n  forests: []`n"
        $r = Invoke-AddChild -ConfigPath $cfg -NameArg "fabrikam.local" -FileArg $script:ValidJson
        $r.ExitCode | Should -Be 0
        $after = [System.IO.File]::ReadAllText($cfg)
        $after | Should -Match "mode: offline"
    }

    It "warns but still adds (with -Force) when _metadata is absent from the JSON" {
        $cfg = New-IsolatedConfig
        $r = Invoke-AddChild -ConfigPath $cfg -NameArg "nometa.local" -FileArg $script:NoMetadataJson -Force
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "_metadata block absent"
        $r.Output | Should -Match "added to workspace"
        $after = [System.IO.File]::ReadAllText($cfg)
        $after | Should -Match "name: nometa\.local"
    }
}

# ---------------------------------------------------------------------------
# Invoke-Remove -- daily-use CRUD entry point, destructive by nature. A wrong
# line-range calculation in the Remove-ForestFromConfig text surgery it
# depends on would corrupt config.yaml beyond just the target forest, so
# these tests assert on the FULL post-removal file content, not just exit
# code and message text.
#
# All tests use -Force to skip the interactive y/N confirmation, same
# reasoning as Invoke-Add above.
# ---------------------------------------------------------------------------
Describe "Invoke-Remove (child process)" {
    BeforeAll {
        $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..\installer\Manage-Workspaces.ps1")).Path
        $script:WorkDir    = Join-Path ([System.IO.Path]::GetTempPath()) ("lmcp-remove-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

        # A real JSON file the config entry points to -- used to verify
        # Invoke-Remove's own claim ("The JSON file will NOT be deleted").
        $script:RealJsonFile = Join-Path $script:WorkDir "contoso.local.json"
        Set-Content -Path $script:RealJsonFile -Encoding UTF8 -Value '{"users":[]}'

        function global:Invoke-RemoveChild {
            param([string]$ConfigPath, [string]$NameArg, [switch]$Force)
            $psExe = "powershell.exe"
            $argList = @(
                "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", $script:ScriptPath,
                "-Remove", "-Config", $ConfigPath
            )
            if ($NameArg) { $argList += @("-Name", $NameArg) }
            if ($Force) { $argList += "-Force" }
            $out = & $psExe @argList 2>&1
            return [PSCustomObject]@{
                Output   = ($out | Out-String)
                ExitCode = $LASTEXITCODE
            }
        }

        function global:New-IsolatedConfig {
            param([string]$Content)
            $path = Join-Path $script:WorkDir ("config." + [guid]::NewGuid().ToString("N") + ".yaml")
            Set-Content -Path $path -Encoding UTF8 -Value $Content
            return $path
        }

        $script:SingleForestConfig = "profile: A`n`nworkspace:`n  forests:`n    - name: contoso.local`n      module: ad-core`n      file: $($script:RealJsonFile.Replace('\','/'))`n"

        $script:ThreeForestConfig =
            "profile: A`n`nworkspace:`n  forests:`n" +
            "    - name: alpha.local`n      module: ad-core`n      relation: standalone`n" +
            "    - name: contoso.local`n      module: ad-core`n      file: $($script:RealJsonFile.Replace('\','/'))`n" +
            "    - name: omega.local`n      module: ad-core`n      dc: dc01.omega.local`n"
    }

    AfterAll {
        # [System.IO.Directory]::Exists(), not Test-Path -- see the file
        # header note on the Test-Path stub leak from Get-ConfigPathFromHive/
        # Resolve-ConfigPath.
        if ($script:WorkDir -and [System.IO.Directory]::Exists($script:WorkDir)) {
            Remove-Item $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item function:global:Invoke-RemoveChild -ErrorAction SilentlyContinue
        Remove-Item function:global:New-IsolatedConfig -ErrorAction SilentlyContinue
    }

    It "requires -Name: exits 1 with an explicit error, config.yaml untouched" {
        $cfg = New-IsolatedConfig -Content $script:SingleForestConfig
        $before = [System.IO.File]::ReadAllText($cfg)
        $r = Invoke-RemoveChild -ConfigPath $cfg -Force
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "-Name is required"
        [System.IO.File]::ReadAllText($cfg) | Should -Be $before
    }

    It "reports an explicit error for a forest that does not exist, config.yaml untouched" {
        $cfg = New-IsolatedConfig -Content $script:SingleForestConfig
        $before = [System.IO.File]::ReadAllText($cfg)
        $r = Invoke-RemoveChild -ConfigPath $cfg -NameArg "ghost.local" -Force
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "not found in config\.yaml"
        [System.IO.File]::ReadAllText($cfg) | Should -Be $before
    }

    It "removes the only forest: exits 0, config.yaml no longer contains it" {
        $cfg = New-IsolatedConfig -Content $script:SingleForestConfig
        $r = Invoke-RemoveChild -ConfigPath $cfg -NameArg "contoso.local" -Force
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "removed from workspace"
        $after = [System.IO.File]::ReadAllText($cfg)
        $after | Should -Not -Match "name: contoso\.local"
    }

    It "does NOT delete the JSON file the removed forest pointed to" {
        # [System.IO.File]::Exists(), not Test-Path: an earlier Describe
        # block in this same file (Get-ConfigPathFromHive/Resolve-ConfigPath)
        # stubs Test-Path globally and its cleanup does not fully restore
        # the real cmdlet for the rest of the run (verified empirically --
        # see the note in this file's header). The .NET method sidesteps
        # that leak entirely instead of depending on a fix to it.
        $cfg = New-IsolatedConfig -Content $script:SingleForestConfig
        [System.IO.File]::Exists($script:RealJsonFile) | Should -BeTrue
        $r = Invoke-RemoveChild -ConfigPath $cfg -NameArg "contoso.local" -Force
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "JSON file was NOT deleted"
        [System.IO.File]::Exists($script:RealJsonFile) | Should -BeTrue
    }

    It "removes only the targeted forest out of three, leaving the other two intact" {
        $cfg = New-IsolatedConfig -Content $script:ThreeForestConfig
        $r = Invoke-RemoveChild -ConfigPath $cfg -NameArg "contoso.local" -Force
        $r.ExitCode | Should -Be 0
        $after = [System.IO.File]::ReadAllText($cfg)
        $after | Should -Not -Match "name: contoso\.local"
        $after | Should -Match "name: alpha\.local"
        $after | Should -Match "name: omega\.local"
        # The untouched forests' own fields must survive byte-correct --
        # this is exactly the off-by-one line-range bug class already found
        # twice in this file (Get-Forests/#127, Get-RawGroupMemberDNs/#134).
        $after | Should -Match "relation: standalone"
        $after | Should -Match "dc: dc01\.omega\.local"
    }

    It "removing the first forest of three does not corrupt the remaining two" {
        $cfg = New-IsolatedConfig -Content $script:ThreeForestConfig
        $r = Invoke-RemoveChild -ConfigPath $cfg -NameArg "alpha.local" -Force
        $r.ExitCode | Should -Be 0
        $after = [System.IO.File]::ReadAllText($cfg)
        $after | Should -Not -Match "name: alpha\.local"
        $after | Should -Match "name: contoso\.local"
        $after | Should -Match "name: omega\.local"
    }

    It "removing the last forest of three does not corrupt the remaining two" {
        $cfg = New-IsolatedConfig -Content $script:ThreeForestConfig
        $r = Invoke-RemoveChild -ConfigPath $cfg -NameArg "omega.local" -Force
        $r.ExitCode | Should -Be 0
        $after = [System.IO.File]::ReadAllText($cfg)
        $after | Should -Not -Match "name: omega\.local"
        $after | Should -Match "name: alpha\.local"
        $after | Should -Match "name: contoso\.local"
    }
}

# ---------------------------------------------------------------------------
Describe "Invoke-RepairMetadata -- zero forests (child process)" {
    BeforeAll {
        $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..\installer\Manage-Workspaces.ps1")).Path
        $script:WorkDir    = Join-Path ([System.IO.Path]::GetTempPath()) ("lmcp-repair-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

        $script:ZeroForestConfig = Join-Path $script:WorkDir "config.zero-forests.yaml"
        Set-Content -Path $script:ZeroForestConfig -Encoding UTF8 -Value @'
profile: A

workspace:
  forests: []
'@

        function global:Invoke-RepairMetadataChild {
            param([string]$ConfigPath, [string]$NameArg)
            $psExe = "powershell.exe"
            $argList = @(
                "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", $script:ScriptPath,
                "-RepairMetadata", "-Config", $ConfigPath
            )
            if ($NameArg) { $argList += @("-Name", $NameArg) }
            $out = & $psExe @argList 2>&1
            return [PSCustomObject]@{
                Output   = ($out | Out-String)
                ExitCode = $LASTEXITCODE
            }
        }
    }

    AfterAll {
        if ($script:WorkDir -and (Test-Path $script:WorkDir)) {
            Remove-Item $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not crash with PropertyNotFoundStrict on a config with zero forests" {
        $r = Invoke-RepairMetadataChild -ConfigPath $script:ZeroForestConfig
        $r.Output | Should -Not -Match "PropertyNotFoundStrict"
        $r.Output | Should -Not -Match "cannot be found"
    }

    It "exits 0 with a clean 'nothing to repair' message for zero forests" {
        $r = Invoke-RepairMetadataChild -ConfigPath $script:ZeroForestConfig
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "Nothing to repair"
    }

    It "does not crash and exits 1 with an explicit error for -Name on a zero-forest config" {
        # Second fixed call site: the -Name pre-filter branch, unreachable
        # from the plain -RepairMetadata run above.
        $r = Invoke-RepairMetadataChild -ConfigPath $script:ZeroForestConfig -NameArg "ghost.local"
        $r.Output | Should -Not -Match "PropertyNotFoundStrict"
        $r.Output | Should -Not -Match "cannot be found"
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "not found in config.yaml"
    }
}

# ---------------------------------------------------------------------------
# Invoke-Validate -Name -- same pipe-collapse bug found and fixed above for
# Invoke-RepairMetadata, same root cause (Where-Object on zero input assigns
# $null, not an empty array; .Count on it throws PropertyNotFoundStrict
# under Set-StrictMode). Marco's manual field test covered -Validate WITHOUT
# -Name (which never hits this -- it only reaches a bare `foreach` on the
# unfiltered Get-Forests result, and foreach on $null is a silent no-op).
# -Validate -Name on a zero-forest (or non-matching -Name) config is exactly
# the untested combination -- this Describe block closes that gap.
# ---------------------------------------------------------------------------
Describe "Invoke-Validate -Name -- zero/non-matching forests (child process)" {
    BeforeAll {
        $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..\installer\Manage-Workspaces.ps1")).Path
        $script:WorkDir    = Join-Path ([System.IO.Path]::GetTempPath()) ("lmcp-validate-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

        $script:ZeroForestConfig = Join-Path $script:WorkDir "config.zero-forests.yaml"
        Set-Content -Path $script:ZeroForestConfig -Encoding UTF8 -Value @'
profile: A

workspace:
  forests: []
'@

        function global:Invoke-ValidateChild {
            param([string]$ConfigPath, [string]$NameArg)
            $psExe = "powershell.exe"
            $argList = @(
                "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", $script:ScriptPath,
                "-Validate", "-Config", $ConfigPath,
                "-Name", $NameArg
            )
            $out = & $psExe @argList 2>&1
            return [PSCustomObject]@{
                Output   = ($out | Out-String)
                ExitCode = $LASTEXITCODE
            }
        }
    }

    AfterAll {
        if ($script:WorkDir -and (Test-Path $script:WorkDir)) {
            Remove-Item $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not crash and exits 1 with an explicit error for -Validate -Name on a zero-forest config" {
        $r = Invoke-ValidateChild -ConfigPath $script:ZeroForestConfig -NameArg "ghost.local"
        $r.Output | Should -Not -Match "PropertyNotFoundStrict"
        $r.Output | Should -Not -Match "cannot be found"
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match "not found in config.yaml"
    }
}
