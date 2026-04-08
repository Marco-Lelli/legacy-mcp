# mcp-remote-live.ps1 -- wrapper per Claude Desktop (Profile B)
# La API key viene letta da .legacymcp-key (cifrato con DPAPI user-scope).
# Per generare .legacymcp-key eseguire Setup-LegacyMCPClient.ps1.
#
# ADATTARE per ogni deployment:
#   - $ServerUrl: URL del server MCP (passato da claude_desktop_config.json
#     tramite il parametro -ServerUrl, oppure modificare il default qui sotto)
#   - $CaCertPath: percorso del certificato CA del server MCP

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