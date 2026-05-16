# LegacyMCP.Client.psm1
# Client setup: claude_desktop_config.json management (Profile A and B),
# MSIX vs exe detection, mcp-remote configuration, API key client-side.

function Get-LMClaudeConfigPath {
    # Auto-detects claude_desktop_config.json path.
    # Priority: MSIX (%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\...)
    #           -> exe (%APPDATA%\Claude\)
    #           -> AppX package check -> fallback exe
    # Logic extracted from Setup-LegacyMCPClient.ps1
    throw "Not implemented"
}

function Set-LMClaudeConfigProfileA {
    [CmdletBinding()]
    param(
        [string]$PythonExe,
        [string]$ConfigYamlPath,
        [string]$ClaudeConfigPath
    )
    # Writes legacymcp entry in claude_desktop_config.json for Profile A
    # Direct python.exe invocation (no mcp-remote)
    # Falls back to Write-Host template if write fails (P4)
    throw "Not implemented"
}

function Set-LMClaudeConfigProfileB {
    [CmdletBinding()]
    param(
        [string]$BatPath,
        [string]$ClaudeConfigPath
    )
    # Writes legacymcp-live entry in claude_desktop_config.json for Profile B
    # Uses mcp-remote-live.bat as command
    # Logic extracted from Setup-LegacyMCPClient.ps1
    throw "Not implemented"
}

function New-LMMcpRemoteBat {
    [CmdletBinding()]
    param(
        [string]$ServerUrl,
        [string]$CertPath,
        [string]$OutputPath
    )
    throw "Not implemented"
}

function Protect-LMClientApiKey {
    [CmdletBinding()]
    param(
        [string]$ApiKey,
        [string]$OutputPath
    )
    # DPAPI user-scope encryption -> .legacymcp-key file
    throw "Not implemented"
}

Export-ModuleMember -Function *
