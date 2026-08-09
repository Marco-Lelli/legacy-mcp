# Pester tests for the module -> host-script logging boundary.
#
# Regression cover for the AUSL Romagna field failure (2026-08-06): a direct
# Write-CollectorLog call from inside Users.psm1 threw CommandNotFoundException
# and cost the ENTIRE Users section.
#
# Why the existing suites missed it: every earlier check ran the host script
# with "powershell.exe -File", where the script's top-level scope is
# effectively global and modules DO resolve script-level functions. The field
# launches ".\Collect-ADData.ps1" from an open session, where the script scope
# is a child of global and modules DO NOT. The invocation style was the
# variable that mattered, and it was never exercised.
#
# These tests therefore run a real host script BOTH ways, in a child process,
# and assert the section survives either way.

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    $script:ModulesDir = Join-Path $script:RepoRoot "collector\modules"
    $script:WorkDir    = Join-Path ([System.IO.Path]::GetTempPath()) ("lmcp-scope-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

    # Host script mirroring Collect-ADData.ps1: same import order, StrictMode,
    # script-scoped counters, GLOBAL Write-CollectorLog, Invoke-Section wrapper.
    # Get-ADUser is stubbed globally, as the real AD module would be, and forces
    # both aggregate warning paths in Get-UsersData.
    $hostScript = @'
param([string]$ModulesDir)
Import-Module (Join-Path $ModulesDir "Logging.psm1") -Force
Import-Module (Join-Path $ModulesDir "Membership.psm1") -Force
Import-Module (Join-Path $ModulesDir "Groups.psm1") -Force
Import-Module (Join-Path $ModulesDir "Users.psm1") -Force

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:sectionsOK = 0; $script:sectionsWarn = 0; $script:sectionsError = 0

function global:Write-CollectorLog {
    param([string]$Level, [string]$Section, [string]$Message)
    switch ($Level) {
        "INFO"  { $script:sectionsOK++ }
        "WARN"  { $script:sectionsWarn++ }
        "ERROR" { $script:sectionsError++ }
    }
}

function Invoke-Section([string]$Name, [scriptblock]$Block) {
    try { return & $Block }
    catch {
        Write-CollectorLog -Level ERROR -Section $Name -Message "exception: $($_.Exception.Message)"
        return $null
    }
}

function global:Get-ADUser {
    param($Filter, $Properties, [string]$Server, $Credential, [string]$Identity)
    return @(
        [PSCustomObject]@{ SamAccountName="u1"; userAccountControl=512;   CannotChangePassword=$false; mail=$null; SIDHistory=@() },
        [PSCustomObject]@{ SamAccountName="u2"; userAccountControl=$null; CannotChangePassword=$null;  mail=$null; SIDHistory=@() }
    )
}

$users = Invoke-Section "Users" { Get-UsersData -CommonParams @{} }
$count = if ($null -eq $users) { -1 } else { @($users).Count }
Write-Output "USERS=$count WARN=$($script:sectionsWarn) ERROR=$($script:sectionsError)"
'@
    $script:HostPath = Join-Path $script:WorkDir "HostScript.ps1"
    Set-Content -Path $script:HostPath -Value $hostScript -Encoding UTF8

    function global:Invoke-HostScript {
        param([ValidateSet("File", "Session")][string]$Style)
        $psExe = "powershell.exe"
        if ($Style -eq "File") {
            $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File $script:HostPath -ModulesDir $script:ModulesDir 2>&1
        } else {
            # Invocation from an already-open session: the case that failed in the field.
            $cmd = "& '$($script:HostPath)' -ModulesDir '$($script:ModulesDir)'"
            $out = & $psExe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1
        }
        return ($out | Out-String)
    }
}

AfterAll {
    if ($script:WorkDir -and (Test-Path $script:WorkDir)) {
        Remove-Item $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Write-CollectorLog reachability from collector modules" {

    It "keeps the Users section when launched with -File" {
        $out = Invoke-HostScript -Style File
        $out | Should -Match "USERS=2"
        $out | Should -Not -Match "not recognized"
    }

    It "keeps the Users section when launched from an open session (field style)" {
        # The exact scenario that lost the whole Users section on AUSL Romagna.
        $out = Invoke-HostScript -Style Session
        $out | Should -Match "USERS=2"
        $out | Should -Not -Match "not recognized"
    }

    It "still records the aggregate warnings, not just avoiding the crash" {
        # A shim that silently degraded every warning to Write-Warning would
        # pass the tests above while quietly losing sections_warn and the log.
        $out = Invoke-HostScript -Style Session
        $out | Should -Match "WARN=2"
        $out | Should -Match "ERROR=0"
    }
}

Describe "Write-SafeCollectorLog fallback" {
    BeforeAll { Import-Module (Join-Path $script:ModulesDir "Logging.psm1") -Force }

    It "does not throw when no host Write-CollectorLog exists" {
        { Write-SafeCollectorLog -Level WARN -Section "X" -Message "standalone" 3>$null } |
            Should -Not -Throw
    }
}
