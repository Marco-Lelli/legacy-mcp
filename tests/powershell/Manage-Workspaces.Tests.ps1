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
# This also means only the 8 functions listed below exist in this file's
# scope; anything calling Write-ConfigRaw or other script-scoped helpers is
# out of reach here by design (side-effect functions, out of scope for
# Fase 1's priority list). Get-Forests is the one exception that needs a
# dependency stub: it calls Read-ConfigRaw, which is provided per-test as a
# global function override (Describe "Get-Forests" below) instead of being
# extracted, since its real implementation reads an actual file.

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
        'Get-JsonProperty', 'Resolve-Module', 'Get-Forests'
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

    # Joined and evaluated once: defines all 7 functions in this scope, with
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
        Remove-Item function:global:Test-Path -ErrorAction SilentlyContinue
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
        Remove-Item function:global:Test-Path -ErrorAction SilentlyContinue
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
