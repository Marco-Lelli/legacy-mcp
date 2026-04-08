# mcp-remote-live.ps1 -- wrapper per Claude Desktop (Profile B)
# La API key viene letta da .legacymcp-key (cifrato con DPAPI user-scope).
# Per generare .legacymcp-key eseguire Setup-LegacyMCPClient.ps1.
#
# ADATTARE per ogni deployment:
#   - $ServerUrl: URL del server MCP (passato da claude_desktop_config.json
#     tramite il parametro -ServerUrl, oppure modificare il default qui sotto)
#   - NODE_EXTRA_CA_CERTS: impostato da Setup-LegacyMCPClient.ps1 come variabile
#     d'ambiente User-scope; non serve modificarlo qui.

param(
    [string]$ServerUrl = "https://lorenzo.house.local:8000/mcp"
)

$keyFile = Join-Path $PSScriptRoot ".legacymcp-key"
if (-not (Test-Path $keyFile)) {
    Write-Error "API key not found. Run Setup-LegacyMCPClient.ps1 first."
    exit 1
}

$secure = Get-Content $keyFile | ConvertTo-SecureString
$apiKey = [System.Net.NetworkCredential]::new("", $secure).Password

& npx mcp-remote $ServerUrl --header "Authorization:Bearer $apiKey"
