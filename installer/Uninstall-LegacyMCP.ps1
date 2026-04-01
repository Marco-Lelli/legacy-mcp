#Requires -Version 5.1
<#
.SYNOPSIS
    Remove LegacyMCP from this machine.

.DESCRIPTION
    Stops and removes the LegacyMCP Windows service (if present), unregisters
    the EventLog source, and deletes the registry keys under
    HKLM\SOFTWARE\LegacyMCP\.

    Configuration files (config.yaml) and data files (JSON, logs) are NOT
    removed. Their paths are printed at the end for manual cleanup.

.NOTES
    Requires Administrator privileges.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve paths from registry (best effort -- may already be gone)
# ---------------------------------------------------------------------------
$RegRoot    = 'HKLM:\SOFTWARE\LegacyMCP'
$ConfigPath = $null
$LogPath    = $null

if (Test-Path $RegRoot) {
    $props = Get-ItemProperty -Path $RegRoot -ErrorAction SilentlyContinue
    if ($props) {
        $ConfigPath = $props.ConfigPath
        $LogPath    = $props.LogPath
    }
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-OK   { param([string]$Msg); Write-Host "  [OK]   $Msg" -ForegroundColor Green  }
function Write-Warn { param([string]$Msg); Write-Host "  [WARN] $Msg" -ForegroundColor Yellow }
function Write-Info { param([string]$Msg); Write-Host "  [INFO] $Msg" -ForegroundColor Cyan   }
function Write-Step { param([string]$Msg); Write-Host "`n==> $Msg" -ForegroundColor White     }

# ---------------------------------------------------------------------------
# Administrator check
# ---------------------------------------------------------------------------
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '  [FAIL] Uninstall requires Administrator privileges. Re-run as Administrator.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'LegacyMCP -- Uninstall' -ForegroundColor White
Write-Host ''

# ---------------------------------------------------------------------------
# Step 1 -- Stop and remove NSSM service
# ---------------------------------------------------------------------------
Write-Step 'Step 1 -- Windows Service'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$NssmExe   = Join-Path $ScriptDir 'tools\nssm.exe'

$existingSvc = Get-Service -Name 'LegacyMCP' -ErrorAction SilentlyContinue
if ($existingSvc) {
    Write-Info "Stopping service 'LegacyMCP'..."
    Stop-Service -Name 'LegacyMCP' -Force -ErrorAction SilentlyContinue

    if (Test-Path $NssmExe) {
        & $NssmExe remove LegacyMCP confirm
        Write-OK "Service 'LegacyMCP' removed via NSSM."
    } else {
        # Fallback: sc.exe delete
        Write-Info "nssm.exe not found -- using sc.exe to remove service."
        & sc.exe delete LegacyMCP | Out-Null
        Write-OK "Service 'LegacyMCP' removed via sc.exe."
    }
} else {
    Write-Info "Service 'LegacyMCP' not found -- skipping."
}

# ---------------------------------------------------------------------------
# Step 2 -- Remove EventLog source
# ---------------------------------------------------------------------------
Write-Step 'Step 2 -- EventLog source'

try {
    if ([System.Diagnostics.EventLog]::SourceExists('LegacyMCP')) {
        Remove-EventLog -Source 'LegacyMCP' -ErrorAction SilentlyContinue
        # Also remove the custom log if it exists and is empty
        if ([System.Diagnostics.EventLog]::Exists('LegacyMCP')) {
            Remove-EventLog -LogName 'LegacyMCP' -ErrorAction SilentlyContinue
        }
        Write-OK "EventLog source 'LegacyMCP' removed."
    } else {
        Write-Info "EventLog source 'LegacyMCP' not found -- skipping."
    }
} catch {
    Write-Warn "Could not remove EventLog source: $_"
}

# ---------------------------------------------------------------------------
# Step 3 -- Registry
# ---------------------------------------------------------------------------
Write-Step 'Step 3 -- Registry'

if (Test-Path $RegRoot) {
    Remove-Item -Path $RegRoot -Recurse -Force
    Write-OK "Registry key '$RegRoot' removed."
} else {
    Write-Info "Registry key '$RegRoot' not found -- skipping."
}

# ---------------------------------------------------------------------------
# Step 4 -- Summary: preserved files
# ---------------------------------------------------------------------------
Write-Step 'Step 4 -- Preserved files'

Write-Host ''
Write-Host '  The following files were NOT removed:' -ForegroundColor Yellow
Write-Host ''

if ($ConfigPath) {
    Write-Host "    Configuration : $ConfigPath" -ForegroundColor Yellow
} else {
    Write-Host '    Configuration : (path unknown -- check install directory)' -ForegroundColor Yellow
}

if ($LogPath) {
    Write-Host "    Logs          : $LogPath" -ForegroundColor Yellow
} else {
    Write-Host '    Logs          : (path unknown -- check install directory)' -ForegroundColor Yellow
}

Write-Host ''
Write-Warn 'JSON data files (AD exports) are classified Confidential/Restricted.'
Write-Warn 'Delete them securely when no longer needed (e.g. cipher /w or Eraser).'
Write-Host ''
Write-Host 'LegacyMCP uninstall complete.' -ForegroundColor Green
Write-Host ''
