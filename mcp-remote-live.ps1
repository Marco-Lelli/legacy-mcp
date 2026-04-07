# mcp-remote-live.ps1 -- wrapper per Claude Desktop (Profile B)
# La API key viene letta da .legacymcp-key (cifrato con DPAPI user-scope).
# Per generare .legacymcp-key eseguire Setup-LegacyMCPClient.ps1.
#
# ADATTARE per ogni deployment:
#   - NODE_EXTRA_CA_CERTS: path al certificato TLS del server MCP
#   - URL in npx mcp-remote: hostname e porta del server MCP
#
# Esempio per il lab LORENZO:
#   NODE_EXTRA_CA_CERTS = C:\GIT\legacy-mcp\certs\lorenzo.crt
#   URL                 = https://lorenzo.house.local:8000/mcp

$env:NODE_EXTRA_CA_CERTS = "C:\GIT\legacy-mcp\certs\lorenzo.crt"

$keyFile = Join-Path $PSScriptRoot ".legacymcp-key"
if (-not (Test-Path $keyFile)) {
    Write-Error "API key not found. Run Setup-LegacyMCPClient.ps1 first."
    exit 1
}

$secure = Get-Content $keyFile | ConvertTo-SecureString
$apiKey = [System.Net.NetworkCredential]::new("", $secure).Password

& npx mcp-remote https://lorenzo.house.local:8000/mcp --header "Authorization:Bearer $apiKey"
