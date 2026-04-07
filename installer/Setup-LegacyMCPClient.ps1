#Requires -Version 5.1
<#
.SYNOPSIS
    Configure a consultant PC to connect to a LegacyMCP Profile B server.

.DESCRIPTION
    Sets AUTH_HEADER and NODE_EXTRA_CA_CERTS as User-scope environment variables,
    then adds or updates the legacymcp-live entry in claude_desktop_config.json.

    The API key is stored only in the User environment -- never written to disk in
    plain text. The JSON config uses ${AUTH_HEADER} as a reference so Claude Desktop
    reads the value from the environment at startup.

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
# Step 3 -- Set User environment variables
# ---------------------------------------------------------------------------
Write-Step 'Step 3 -- User environment variables'

$authHeaderValue = "Bearer $ApiKey"
[Environment]::SetEnvironmentVariable('AUTH_HEADER', $authHeaderValue, 'User')
Write-OK 'AUTH_HEADER set as User environment variable.'

[Environment]::SetEnvironmentVariable('NODE_EXTRA_CA_CERTS', $CaCertPath, 'User')
Write-OK "NODE_EXTRA_CA_CERTS set: $CaCertPath"

# Clear from memory (best effort)
$ApiKey = $null
$authHeaderValue = $null

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

# Build the legacymcp-live entry -- API key is NOT embedded; use env var reference
$liveMcpEntry = [PSCustomObject]@{
    command = 'npx'
    args    = @(
        'mcp-remote',
        $ServerUrl,
        '--header',
        'Authorization:${AUTH_HEADER}'
    )
    env     = [PSCustomObject]@{
        AUTH_HEADER        = '${AUTH_HEADER}'
        NODE_EXTRA_CA_CERTS = '${NODE_EXTRA_CA_CERTS}'
    }
}

# Add or replace legacymcp-live (never touch legacymcp / Profile A entry)
$mcpServers = $config.PSObject.Properties['mcpServers'].Value
if ($mcpServers.PSObject.Properties['legacymcp-live']) {
    $mcpServers.PSObject.Properties.Remove('legacymcp-live')
}
Add-Member -InputObject $mcpServers -NotePropertyName 'legacymcp-live' -NotePropertyValue $liveMcpEntry

# Write back -- UTF-8 without BOM, 2-space indent
# ConvertTo-Json doubles backslashes in Windows paths (\\ -> \\\\).
# Normalise back to \\ so the JSON is valid for Claude Desktop.
$updatedJson = $config | ConvertTo-Json -Depth 10
$updatedJson = $updatedJson -replace '\\\\\\\\', '\\\\'
[System.IO.File]::WriteAllText(
    $ClaudeConfigPath,
    $updatedJson,
    [System.Text.Encoding]::UTF8
)
Write-OK "claude_desktop_config.json updated: $ClaudeConfigPath"

# ---------------------------------------------------------------------------
# Step 5 -- Summary
# ---------------------------------------------------------------------------
Write-Step 'Step 5 -- Summary'

Write-Host ''
Write-Host '  Environment variables set (User scope):' -ForegroundColor White
Write-Host '    AUTH_HEADER         = Bearer ***' -ForegroundColor Cyan
Write-Host "    NODE_EXTRA_CA_CERTS = $CaCertPath" -ForegroundColor Cyan
Write-Host ''
Write-Host '  legacymcp-live entry added to:' -ForegroundColor White
Write-Host "    $ClaudeConfigPath" -ForegroundColor Cyan
Write-Host ''
Write-Host '  Next step: restart Claude Desktop to apply the changes.' -ForegroundColor White
Write-Host ''
Write-OK 'Setup complete.'
Write-Host ''
