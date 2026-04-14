#Requires -Version 5.1
<#
.SYNOPSIS
    Configure a consultant PC to connect to a LegacyMCP Profile B server.

.DESCRIPTION
    Saves the API key as a DPAPI user-scope encrypted file (client\.legacymcp-key),
    generates client\mcp-remote-live.bat as the Claude Desktop entry point, and
    adds or updates the legacymcp-live entry in claude_desktop_config.json.

    The API key is never stored in plain text. It is encrypted with DPAPI
    (user-scope) so only the current Windows user account can decrypt it.
    client\mcp-remote-live.ps1 reads the key at runtime via $PSScriptRoot.

    Claude Desktop cannot use powershell.exe directly as a MCP server command --
    PowerShell emits startup output to stdout before mcp-remote takes control,
    breaking the JSON-RPC framing. The generated BAT file suppresses this with
    -NoProfile -NonInteractive and is the only reliable entry point.

    A backup of claude_desktop_config.json is created before any modification.
    If the backup fails the script exits without touching the config file.

.PARAMETER ApiKey
    Bearer token to authenticate against the LegacyMCP server.
    If omitted, the script prompts interactively (input is masked).

.PARAMETER CaCertPath
    Path to the PEM file of the CA or self-signed certificate used by the server.
    This is the certificate that was generated or provided during server installation
    (typically certs\server.crt on the server machine, copied to this PC).

.PARAMETER ServerUrl
    Full HTTPS URL of the MCP endpoint, e.g. https://LORENZO.house.local:8000/mcp

.PARAMETER ClaudeConfigPath
    Path to claude_desktop_config.json.
    Default: %APPDATA%\Claude\claude_desktop_config.json

.EXAMPLE
    .\Setup-LegacyMCPClient.ps1 -ApiKey "..." -CaCertPath "C:\certs\server.crt" -ServerUrl "https://LORENZO.house.local:8000/mcp"

.EXAMPLE
    .\Setup-LegacyMCPClient.ps1 -CaCertPath "C:\certs\server.crt" -ServerUrl "https://LORENZO.house.local:8000/mcp"
    # prompts for API key interactively
#>

param(
    [string]$ApiKey = '',
    [Parameter(Mandatory)]
    [string]$CaCertPath,
    [Parameter(Mandatory)]
    [string]$ServerUrl,
    [string]$ClaudeConfigPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Guard: must NOT run as Administrator
# When elevated, $env:APPDATA points to the admin profile, not the interactive
# user's profile -- claude_desktop_config.json would be written to the wrong
# location and User-scope environment variables would be set for the wrong account.
# ---------------------------------------------------------------------------
if ([Security.Principal.WindowsIdentity]::GetCurrent().Groups -match 'S-1-5-32-544') {
    Write-Error 'Do not run as Administrator. Run as the normal user account whose Claude Desktop you are configuring.'
    exit 1
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-OK   { param([string]$Msg); Write-Host "  [OK]   $Msg" -ForegroundColor Green  }
function Write-Warn { param([string]$Msg); Write-Host "  [WARN] $Msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg); Write-Host "  [FAIL] $Msg" -ForegroundColor Red    }
function Write-Info { param([string]$Msg); Write-Host "  [INFO] $Msg" -ForegroundColor Cyan   }
function Write-Step { param([string]$Msg); Write-Host "`n==> $Msg" -ForegroundColor White     }

# ---------------------------------------------------------------------------
# Resolve Claude Desktop config path
# ---------------------------------------------------------------------------
if (-not $ClaudeConfigPath) {
    $ClaudeConfigPath = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
}

# ---------------------------------------------------------------------------
# Step 1 -- Collect API key
# ---------------------------------------------------------------------------
Write-Step 'Step 1 -- API key'

if (-not $ApiKey) {
    $secureKey = Read-Host 'API key (input masked)' -AsSecureString
    $bstr      = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    try {
        $ApiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

if (-not $ApiKey) {
    Write-Fail 'API key cannot be empty.'
    exit 1
}
Write-OK 'API key received.'

# ---------------------------------------------------------------------------
# Step 2 -- Validate inputs
# ---------------------------------------------------------------------------
Write-Step 'Step 2 -- Validate inputs'

if (-not (Test-Path $CaCertPath)) {
    Write-Fail "CA certificate file not found: $CaCertPath"
    exit 1
}
Write-OK "CA cert found: $CaCertPath"

if ($ServerUrl -notmatch '^https://') {
    Write-Fail "ServerUrl must start with https://. Got: $ServerUrl"
    exit 1
}
Write-OK "Server URL: $ServerUrl"

# npx available?
if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
    Write-Warn 'npx not found in PATH. Install Node.js (https://nodejs.org) and ensure npx is in PATH.'
    Write-Warn 'Continuing -- npx must be available before Claude Desktop can use this MCP server.'
} else {
    Write-OK 'npx found in PATH.'
}

# ---------------------------------------------------------------------------
# Step 3 -- Save API key (DPAPI user-scope) + generate BAT entry point
# ---------------------------------------------------------------------------
Write-Step 'Step 3 -- Save API key and generate client files'

$repoRoot  = Split-Path $PSScriptRoot -Parent
$clientDir = Join-Path $repoRoot 'client'
if (-not (Test-Path $clientDir)) {
    New-Item -ItemType Directory -Path $clientDir -Force | Out-Null
    Write-OK "Created client directory: $clientDir"
}

# Encrypt the API key with DPAPI (user-scope) and write to client\.legacymcp-key.
# mcp-remote-live.ps1 reads it via $PSScriptRoot, so key and PS1 must be co-located.
$keyFile   = Join-Path $clientDir '.legacymcp-key'
$secure    = $ApiKey | ConvertTo-SecureString -AsPlainText -Force
$encrypted = $secure | ConvertFrom-SecureString
$encrypted | Out-File $keyFile -Encoding UTF8
Write-OK "API key saved (DPAPI encrypted): $keyFile"

# Generate client\mcp-remote-live.bat -- the actual entry point for Claude Desktop.
# PowerShell cannot be used directly as a MCP command: PS emits startup output to
# stdout before mcp-remote takes over, breaking the JSON-RPC framing.
# The BAT file uses -NoProfile -NonInteractive and also sets NODE_EXTRA_CA_CERTS
# explicitly in the process environment (User-scope env vars are not reliably
# inherited by Claude Desktop child processes).
$ps1Path    = Join-Path $clientDir 'mcp-remote-live.ps1'

# Copy mcp-remote-live.ps1 to the client directory.
# Look first alongside this script (installer distribution package);
# fall back to the repository's client\ folder when running from the repo.
$ps1Source = Join-Path $PSScriptRoot 'mcp-remote-live.ps1'
if (-not (Test-Path $ps1Source)) {
    $ps1Source = Join-Path (Split-Path $PSScriptRoot -Parent) 'client\mcp-remote-live.ps1'
}
if (-not (Test-Path $ps1Source)) {
    Write-Fail "mcp-remote-live.ps1 not found. Expected at: $ps1Source"
    exit 1
}
Copy-Item -Path $ps1Source -Destination $ps1Path -Force
Write-OK "mcp-remote-live.ps1 copied to: $ps1Path"

$batPath    = Join-Path $clientDir 'mcp-remote-live.bat'
$batContent  = "@echo off`r`n"
$batContent += "set NODE_EXTRA_CA_CERTS=$CaCertPath`r`n"
$batContent += "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass"
$batContent += " -File `"$ps1Path`""
$batContent += " -ServerUrl `"$ServerUrl`""
$batContent += " -CaCertPath `"$CaCertPath`""
[System.IO.File]::WriteAllText($batPath, $batContent, (New-Object System.Text.UTF8Encoding $false))
Write-OK "BAT entry point generated: $batPath"

# Clear from memory (best effort)
$ApiKey    = $null
$encrypted = $null

# ---------------------------------------------------------------------------
# Step 4 -- Update claude_desktop_config.json
# ---------------------------------------------------------------------------
Write-Step 'Step 4 -- claude_desktop_config.json'

# Ensure parent directory exists
$configDir = Split-Path $ClaudeConfigPath -Parent
if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    Write-OK "Created config directory: $configDir"
}

# Load existing config or start from empty
if (Test-Path $ClaudeConfigPath) {
    # Backup first -- abort if backup fails
    $backupPath = "$ClaudeConfigPath.bak"
    try {
        Copy-Item -Path $ClaudeConfigPath -Destination $backupPath -Force
        Write-OK "Backup created: $backupPath"
    } catch {
        Write-Fail "Failed to create backup of claude_desktop_config.json: $_"
        Write-Fail 'Aborting -- config file not modified.'
        exit 1
    }
    $rawJson = Get-Content $ClaudeConfigPath -Raw -Encoding UTF8
    try {
        $config = $rawJson | ConvertFrom-Json
    } catch {
        Write-Fail "claude_desktop_config.json is not valid JSON: $_"
        Write-Fail "Inspect and repair the file manually, then re-run this script."
        exit 1
    }
} else {
    Write-Info 'claude_desktop_config.json not found -- creating from scratch.'
    $config = [PSCustomObject]@{ mcpServers = [PSCustomObject]@{} }
}

# Ensure mcpServers key exists
if (-not ($config.PSObject.Properties['mcpServers'])) {
    Add-Member -InputObject $config -NotePropertyName 'mcpServers' -NotePropertyValue ([PSCustomObject]@{})
}

# Build the legacymcp-live entry using [ordered]@{} with plain PS path strings.
# ConvertTo-Json handles backslash escaping correctly when paths are inserted as
# normal PS strings -- no post-processing -replace workaround needed.
$liveMcpEntry = [ordered]@{
    command = $batPath
    args    = @()
}

# Add or replace legacymcp-live (never touch legacymcp / Profile A entry)
$mcpServers = $config.PSObject.Properties['mcpServers'].Value
if ($mcpServers.PSObject.Properties['legacymcp-live']) {
    $mcpServers.PSObject.Properties.Remove('legacymcp-live')
}
Add-Member -InputObject $mcpServers -NotePropertyName 'legacymcp-live' -NotePropertyValue $liveMcpEntry

# Write back -- UTF-8 without BOM (New-Object System.Text.UTF8Encoding $false).
# [System.Text.Encoding]::UTF8 includes a BOM that Claude Desktop rejects.
$updatedJson = $config | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText(
    $ClaudeConfigPath,
    $updatedJson,
    (New-Object System.Text.UTF8Encoding $false)
)
Write-OK "claude_desktop_config.json updated: $ClaudeConfigPath"

# ---------------------------------------------------------------------------
# Step 5 -- Summary
# ---------------------------------------------------------------------------
Write-Step 'Step 5 -- Summary'

Write-Host ''
Write-Host '  API key stored (DPAPI encrypted, user-scope):' -ForegroundColor White
Write-Host "    $keyFile" -ForegroundColor Cyan
Write-Host ''
Write-Host '  Claude Desktop entry point generated:' -ForegroundColor White
Write-Host "    $batPath" -ForegroundColor Cyan
Write-Host ''
Write-Host '  legacymcp-live entry added to:' -ForegroundColor White
Write-Host "    $ClaudeConfigPath" -ForegroundColor Cyan
Write-Host ''
Write-Host '  Next step: restart Claude Desktop to apply the changes.' -ForegroundColor White
Write-Host ''
Write-OK 'Setup complete.'
Write-Host ''
