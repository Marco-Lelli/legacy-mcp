# mcp-remote-live.ps1 -- Claude Desktop wrapper (Profile B)
# The API key is read from .legacymcp-key (encrypted with DPAPI user-scope).
# To generate .legacymcp-key run Setup-LegacyMCPClient.ps1.
#
# ADAPT for each deployment:
#   - $ServerUrl: MCP server URL (passed from claude_desktop_config.json
#     via -ServerUrl parameter, or modify the default below)
#   - $CaCertPath: path to the MCP server CA certificate

param(
    [string]$ServerUrl  = "https://lorenzo.house.local:8000/mcp",
    [string]$CaCertPath = ""
)

$keyFile = Join-Path $PSScriptRoot ".legacymcp-key"
if (-not (Test-Path $keyFile)) {
    Write-Error "API key not found. Run Setup-LegacyMCPClient.ps1 first."
    exit 1
}

$secure = Get-Content $keyFile | ConvertTo-SecureString
$apiKey = [System.Net.NetworkCredential]::new("", $secure).Password

if ($CaCertPath -eq "") {
    $CaCertPath = Join-Path $PSScriptRoot "certs\lorenzo.crt"
}
$env:NODE_EXTRA_CA_CERTS = $CaCertPath

& npx mcp-remote $ServerUrl --header "Authorization:Bearer $apiKey"