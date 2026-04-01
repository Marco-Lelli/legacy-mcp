#Requires -Version 5.1
<#
.SYNOPSIS
    Install LegacyMCP for Profile A (local stdio) or Profile B (LAN service).

.DESCRIPTION
    Runs pre-flight checks, creates the Python virtual environment, installs
    dependencies, writes the Windows registry configuration, registers the
    EventLog source, and (for Profile B) installs the NSSM Windows service.
    Finishes with a self-check via Config-LegacyMCP.ps1 -Validate.

.PARAMETER Profile
    A  -- local stdio mode (consultant's machine, no service)
    B  -- shared LAN mode (Windows service via NSSM, requires Administrator)

.EXAMPLE
    .\Install-LegacyMCP.ps1 -Profile A
    .\Install-LegacyMCP.ps1 -Profile B
#>

param(
    [ValidateSet('A','B')]
    [string]$Profile = 'A'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve installation root (parent of installer\)
# ---------------------------------------------------------------------------
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$InstallPath = Split-Path -Parent $ScriptDir   # repo / install root
$NssmExe     = Join-Path $ScriptDir 'tools\nssm.exe'

# Default paths derived from install root
$ConfigPath  = Join-Path $InstallPath 'config\config.yaml'
$LogPath     = Join-Path $InstallPath 'logs'
$VenvPython  = Join-Path $InstallPath '.venv\Scripts\python.exe'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-OK   { param([string]$Msg); Write-Host "  [OK]   $Msg" -ForegroundColor Green  }
function Write-Warn { param([string]$Msg); Write-Host "  [WARN] $Msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg); Write-Host "  [FAIL] $Msg" -ForegroundColor Red    }
function Write-Info { param([string]$Msg); Write-Host "  [INFO] $Msg" -ForegroundColor Cyan   }
function Write-Step { param([string]$Msg); Write-Host "`n==> $Msg" -ForegroundColor White     }

# ---------------------------------------------------------------------------
# Phase 1 -- Pre-flight checks
# ---------------------------------------------------------------------------
Write-Step 'Phase 1 -- Pre-flight checks'

$preflightFail = $false

# Python 3.10+
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd) {
    Write-Fail 'Python not found in PATH. Install Python 3.10 or later.'
    $preflightFail = $true
} else {
    $pyVerRaw = & python --version 2>&1
    if ($pyVerRaw -match 'Python (\d+)\.(\d+)') {
        $pyMajor = [int]$Matches[1]
        $pyMinor = [int]$Matches[2]
        if ($pyMajor -lt 3 -or ($pyMajor -eq 3 -and $pyMinor -lt 10)) {
            Write-Fail "Python $pyMajor.$pyMinor found -- version 3.10 or later required."
            $preflightFail = $true
        } else {
            Write-OK "Python $pyMajor.$pyMinor found."
        }
    } else {
        Write-Fail "Could not determine Python version from: $pyVerRaw"
        $preflightFail = $true
    }
}

# pip
$pipCmd = Get-Command pip -ErrorAction SilentlyContinue
if (-not $pipCmd) {
    Write-Fail 'pip not found. Ensure pip is available in PATH.'
    $preflightFail = $true
} else {
    Write-OK 'pip available.'
}

# PowerShell 5.1 (for collector)
$psVer = $PSVersionTable.PSVersion
if ($psVer.Major -lt 5 -or ($psVer.Major -eq 5 -and $psVer.Minor -lt 1)) {
    Write-Warn "PowerShell $($psVer.Major).$($psVer.Minor) found -- 5.1 or later recommended for the collector."
} else {
    Write-OK "PowerShell $($psVer.Major).$($psVer.Minor) found."
}

# Git (optional)
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Warn 'Git not found -- not required for runtime.'
} else {
    Write-OK 'Git available.'
}

# Administrator check for Profile B
if ($Profile -eq 'B') {
    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Fail 'Profile B installation requires Administrator privileges. Re-run as Administrator.'
        $preflightFail = $true
    } else {
        Write-OK 'Running as Administrator.'
    }
}

# NSSM available for Profile B
if ($Profile -eq 'B') {
    if (-not (Test-Path $NssmExe)) {
        Write-Fail "nssm.exe not found at: $NssmExe"
        Write-Fail 'Download nssm-2.24.zip from https://nssm.cc and place nssm.exe in installer\tools\'
        $preflightFail = $true
    } else {
        Write-OK "nssm.exe found: $NssmExe"
    }
}

if ($preflightFail) {
    Write-Host ''
    Write-Host 'Installation aborted -- resolve the [FAIL] items above and re-run.' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Phase 2 -- Installation
# ---------------------------------------------------------------------------
Write-Step 'Phase 2 -- Installation'

# Create virtual environment
$VenvDir = Join-Path $InstallPath '.venv'
if (-not (Test-Path $VenvDir)) {
    Write-Info "Creating virtual environment in: $VenvDir"
    & python -m venv $VenvDir
    Write-OK 'Virtual environment created.'
} else {
    Write-OK 'Virtual environment already exists -- skipping creation.'
}

# Install package
Write-Info 'Installing LegacyMCP package (pip install -e .) ...'
& "$VenvDir\Scripts\python.exe" -m pip install -e $InstallPath --quiet
Write-OK 'Package installed.'

# Copy config template if config.yaml does not exist
$ConfigExampleKey = if ($Profile -eq 'B') { 'config.example-B.yaml' } else { 'config.example-A.yaml' }
$ConfigExample    = Join-Path $InstallPath "config\$ConfigExampleKey"

if (-not (Test-Path $ConfigPath)) {
    if (Test-Path $ConfigExample) {
        Copy-Item -Path $ConfigExample -Destination $ConfigPath
        Write-OK "config.yaml created from $ConfigExampleKey."
    } else {
        Write-Warn "Template $ConfigExampleKey not found -- config.yaml not created. Create it manually."
    }
} else {
    Write-OK "config.yaml already exists -- not overwritten."
}

# Create log directory
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    Write-OK "Log directory created: $LogPath"
} else {
    Write-OK "Log directory already exists: $LogPath"
}

# ---------------------------------------------------------------------------
# Phase 3 -- Registry
# ---------------------------------------------------------------------------
Write-Step 'Phase 3 -- Windows Registry'

$RegRoot = 'HKLM:\SOFTWARE\LegacyMCP'
if (-not (Test-Path $RegRoot)) {
    New-Item -Path $RegRoot -Force | Out-Null
}

$transport = if ($Profile -eq 'B') { 'streamable-http' } else { 'stdio' }

Set-ItemProperty -Path $RegRoot -Name 'InstallPath' -Value $InstallPath -Type String
Set-ItemProperty -Path $RegRoot -Name 'ConfigPath'  -Value $ConfigPath  -Type String
Set-ItemProperty -Path $RegRoot -Name 'LogPath'     -Value $LogPath     -Type String
Set-ItemProperty -Path $RegRoot -Name 'Profile'     -Value $Profile     -Type String
Set-ItemProperty -Path $RegRoot -Name 'Transport'   -Value $transport   -Type String
Set-ItemProperty -Path $RegRoot -Name 'Port'        -Value 8000         -Type DWord

# Version from pyproject.toml (best effort)
$PyprojectPath = Join-Path $InstallPath 'pyproject.toml'
if (Test-Path $PyprojectPath) {
    $pyprojectContent = Get-Content $PyprojectPath -Raw
    if ($pyprojectContent -match 'version\s*=\s*"([^"]+)"') {
        Set-ItemProperty -Path $RegRoot -Name 'Version' -Value $Matches[1] -Type String
        Write-OK "Version set to $($Matches[1])."
    }
}

# Service subkey
$RegService = 'HKLM:\SOFTWARE\LegacyMCP\Service'
if (-not (Test-Path $RegService)) {
    New-Item -Path $RegService -Force | Out-Null
}
$autoStart = if ($Profile -eq 'B') { 1 } else { 0 }
Set-ItemProperty -Path $RegService -Name 'AutoStart' -Value $autoStart -Type DWord

Write-OK 'Registry written.'

# ---------------------------------------------------------------------------
# Phase 4 -- EventLog
# ---------------------------------------------------------------------------
Write-Step 'Phase 4 -- EventLog registration'

$RegisterEventLog = Join-Path $InstallPath 'scripts\Register-EventLog.ps1'
if (Test-Path $RegisterEventLog) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RegisterEventLog
} else {
    Write-Warn "Register-EventLog.ps1 not found at: $RegisterEventLog -- skipping."
}

# ---------------------------------------------------------------------------
# Phase 5 -- NSSM service (Profile B only)
# ---------------------------------------------------------------------------
if ($Profile -eq 'B') {
    Write-Step 'Phase 5 -- Windows Service (NSSM)'

    $svcPython = $VenvPython

    # Remove existing service if present (idempotent reinstall)
    $existingSvc = Get-Service -Name 'LegacyMCP' -ErrorAction SilentlyContinue
    if ($existingSvc) {
        Write-Info 'Removing existing LegacyMCP service for clean reinstall...'
        Stop-Service -Name 'LegacyMCP' -Force -ErrorAction SilentlyContinue
        & $NssmExe remove LegacyMCP confirm
    }

    & $NssmExe install  LegacyMCP $svcPython '-m' 'legacy_mcp.server'
    & $NssmExe set      LegacyMCP AppDirectory $InstallPath
    & $NssmExe set      LegacyMCP Start SERVICE_AUTO_START
    & $NssmExe set      LegacyMCP AppStdout (Join-Path $LogPath 'legacymcp.log')
    & $NssmExe set      LegacyMCP AppStderr (Join-Path $LogPath 'legacymcp-error.log')

    Write-OK 'LegacyMCP service installed via NSSM.'
    Write-Info "Start with: Start-Service LegacyMCP"
    Write-Info "Status:     Get-Service LegacyMCP"
}

# ---------------------------------------------------------------------------
# Phase 6 -- Output
# ---------------------------------------------------------------------------
Write-Step 'Phase 6 -- Next steps'

if ($Profile -eq 'A') {
    $escapedPython = $VenvPython -replace '\\', '\\'
    Write-Host ''
    Write-Host '=========================================='
    Write-Host '  Add this block to:'
    Write-Host '  %APPDATA%\Claude\claude_desktop_config.json'
    Write-Host '=========================================='
    Write-Host ''
    Write-Host '{'
    Write-Host '  "mcpServers": {'
    Write-Host '    "legacymcp": {'
    Write-Host "      `"command`": `"$escapedPython`","
    Write-Host '      "args": ["-m", "legacy_mcp.server"]'
    Write-Host '    }'
    Write-Host '  }'
    Write-Host '}'
    Write-Host ''
    Write-Host 'Restart Claude Desktop to activate LegacyMCP.'
    Write-Host '=========================================='
    Write-Host ''
} else {
    Write-Host ''
    Write-Info "Service installed. Start it with:"
    Write-Host "    Start-Service LegacyMCP" -ForegroundColor White
    Write-Info "Verify status:"
    Write-Host "    Get-Service LegacyMCP" -ForegroundColor White
    Write-Info "Check logs:"
    Write-Host "    Get-Content '$LogPath\legacymcp.log' -Tail 50 -Wait" -ForegroundColor White
    Write-Host ''
    Write-Info "Configure Claude Desktop or your MCP client to connect via:"
    Write-Host "    http://<server-ip>:8000/mcp" -ForegroundColor White
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Phase 7 -- Self-check
# ---------------------------------------------------------------------------
Write-Step 'Phase 7 -- Self-check (Config-LegacyMCP.ps1 -Validate)'

$ConfigScript = Join-Path $ScriptDir 'Config-LegacyMCP.ps1'
if (Test-Path $ConfigScript) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ConfigScript -Validate
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host 'Self-check FAILED. Review the [FAIL] items above before using LegacyMCP.' -ForegroundColor Red
        Write-Host "Run '.\installer\Config-LegacyMCP.ps1 -Validate' after resolving issues." -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Warn "Config-LegacyMCP.ps1 not found -- skipping self-check."
}

Write-Host ''
Write-Host 'LegacyMCP installation complete.' -ForegroundColor Green
Write-Host ''
