# LegacyMCP.Client.psm1
# Client setup: claude_desktop_config.json management (Profile A and B),
# MSIX vs exe detection, mcp-remote configuration, API key client-side.

Import-Module (Join-Path $PSScriptRoot 'LegacyMCP.Common.psm1') -Force -Global

# ---------------------------------------------------------------------------
# Get-LMClaudeConfigPath
# ---------------------------------------------------------------------------

function Get-LMClaudeConfigPath {
    # Claude Desktop MSIX virtualizes %APPDATA%\Claude\ to a sandboxed path under
    # %LOCALAPPDATA%\Packages\. The suffix pzs8sxrjxfjjc is derived from Anthropic's
    # signing certificate -- stable across versions and users.
    $msixConfig = Join-Path $env:LOCALAPPDATA `
        'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json'
    $exeConfig  = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'

    if (Test-Path $msixConfig) {
        Write-LMInfo 'Detected Claude Desktop installed via Microsoft Store / MSIX.'
        return $msixConfig
    }
    if (Test-Path $exeConfig) {
        Write-LMInfo 'Detected Claude Desktop installed via direct .exe installer.'
        return $exeConfig
    }
    $msixInstalled = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue
    if ($msixInstalled) {
        Write-LMInfo 'Claude Desktop (MSIX) registered but config not yet created -- will create at MSIX path.'
        return $msixConfig
    }
    Write-LMInfo 'Claude Desktop config not found -- defaulting to standard path.'
    return $exeConfig
}

# ---------------------------------------------------------------------------
# Set-LMClaudeConfigProfileA
# ---------------------------------------------------------------------------

function Set-LMClaudeConfigProfileA {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PythonExe,
        [Parameter(Mandatory)]
        [string]$ClaudeConfigPath
    )

    $configDir = Split-Path $ClaudeConfigPath -Parent
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Write-LMInfo "Created config directory: $configDir"
    }

    if (Test-Path $ClaudeConfigPath) {
        $backupPath = "$ClaudeConfigPath.bak"
        try {
            Copy-Item -Path $ClaudeConfigPath -Destination $backupPath -Force
            Write-LMInfo "Backup created: $backupPath"
        } catch {
            Write-LMFail "Failed to create backup of claude_desktop_config.json: $_"
            Write-LMFail 'Aborting -- config file not modified.'
            throw
        }
        $rawJson = Get-Content $ClaudeConfigPath -Raw -Encoding UTF8
        try {
            $config = $rawJson | ConvertFrom-Json
        } catch {
            Write-LMFail "claude_desktop_config.json is not valid JSON: $_"
            throw
        }
    } else {
        Write-LMInfo 'claude_desktop_config.json not found -- creating from scratch.'
        $config = [PSCustomObject]@{ mcpServers = [PSCustomObject]@{} }
    }

    if (-not ($config.PSObject.Properties['mcpServers'])) {
        Add-Member -InputObject $config -NotePropertyName 'mcpServers' -NotePropertyValue ([PSCustomObject]@{})
    }

    $profileAEntry = [ordered]@{
        command = $PythonExe
        args    = @('-m', 'legacy_mcp.server')
    }

    $mcpServers = $config.PSObject.Properties['mcpServers'].Value
    if ($mcpServers.PSObject.Properties['legacymcp']) {
        $mcpServers.PSObject.Properties.Remove('legacymcp')
    }
    Add-Member -InputObject $mcpServers -NotePropertyName 'legacymcp' -NotePropertyValue $profileAEntry

    try {
        $updatedJson = $config | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText(
            $ClaudeConfigPath,
            $updatedJson,
            (New-Object System.Text.UTF8Encoding $false)
        )
        Write-LMOK "claude_desktop_config.json updated: $ClaudeConfigPath"
    } catch {
        # P4: fallback to printed template if write fails
        Write-LMFail "Failed to write claude_desktop_config.json: $_"
        Write-LMInfo 'Add this entry manually under "mcpServers" in claude_desktop_config.json:'
        Write-LMInfo "  ""legacymcp"": { ""command"": ""$PythonExe"", ""args"": [""-m"", ""legacy_mcp.server""] }"
    }
}

# ---------------------------------------------------------------------------
# Set-LMClaudeConfigProfileB
# ---------------------------------------------------------------------------

function Set-LMClaudeConfigProfileB {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BatPath,
        [Parameter(Mandatory)]
        [string]$ClaudeConfigPath
    )

    $configDir = Split-Path $ClaudeConfigPath -Parent
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Write-LMInfo "Created config directory: $configDir"
    }

    if (Test-Path $ClaudeConfigPath) {
        $backupPath = "$ClaudeConfigPath.bak"
        try {
            Copy-Item -Path $ClaudeConfigPath -Destination $backupPath -Force
            Write-LMInfo "Backup created: $backupPath"
        } catch {
            Write-LMFail "Failed to create backup of claude_desktop_config.json: $_"
            Write-LMFail 'Aborting -- config file not modified.'
            throw
        }
        $rawJson = Get-Content $ClaudeConfigPath -Raw -Encoding UTF8
        try {
            $config = $rawJson | ConvertFrom-Json
        } catch {
            Write-LMFail "claude_desktop_config.json is not valid JSON: $_"
            throw
        }
    } else {
        Write-LMInfo 'claude_desktop_config.json not found -- creating from scratch.'
        $config = [PSCustomObject]@{ mcpServers = [PSCustomObject]@{} }
    }

    if (-not ($config.PSObject.Properties['mcpServers'])) {
        Add-Member -InputObject $config -NotePropertyName 'mcpServers' -NotePropertyValue ([PSCustomObject]@{})
    }

    # legacymcp-live entry only -- never touch legacymcp (Profile A)
    $liveMcpEntry = [ordered]@{
        command = $BatPath
        args    = @()
    }

    $mcpServers = $config.PSObject.Properties['mcpServers'].Value
    if ($mcpServers.PSObject.Properties['legacymcp-live']) {
        $mcpServers.PSObject.Properties.Remove('legacymcp-live')
    }
    Add-Member -InputObject $mcpServers -NotePropertyName 'legacymcp-live' -NotePropertyValue $liveMcpEntry

    $updatedJson = $config | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText(
        $ClaudeConfigPath,
        $updatedJson,
        (New-Object System.Text.UTF8Encoding $false)
    )
    Write-LMOK "claude_desktop_config.json updated: $ClaudeConfigPath"
}

# ---------------------------------------------------------------------------
# New-LMMcpRemoteBat
# ---------------------------------------------------------------------------

function New-LMMcpRemoteBat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerUrl,
        [Parameter(Mandatory)]
        [string]$CertPath,
        [Parameter(Mandatory)]
        [string]$Ps1Path,
        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    # BAT wrapper is required: PowerShell emits stdout during startup that breaks
    # JSON-RPC framing. -NoProfile -NonInteractive suppresses this.
    $bat  = "@echo off`r`n"
    $bat += "set NODE_EXTRA_CA_CERTS=$CertPath`r`n"
    $bat += "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned"
    $bat += " -File `"$Ps1Path`""
    $bat += " -ServerUrl `"$ServerUrl`""
    $bat += " -CaCertPath `"$CertPath`""

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($OutputPath, $bat, $utf8NoBom)
    } catch {
        Write-Error "New-LMMcpRemoteBat: Failed to write BAT file to '$OutputPath': $_"
        exit 1
    }
    Write-LMOK "BAT entry point generated: $OutputPath"
}

# ---------------------------------------------------------------------------
# Protect-LMClientApiKey  (DPAPI user-scope via ConvertFrom-SecureString)
# ---------------------------------------------------------------------------

function Protect-LMClientApiKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ApiKey,
        [Parameter(Mandatory)]
        [string]$OutputPath
    )
    # ConvertFrom-SecureString without -Key = DPAPI user-scope.
    # Only the same Windows user can decrypt with ConvertTo-SecureString.
    $secure    = $ApiKey | ConvertTo-SecureString -AsPlainText -Force
    $encrypted = $secure | ConvertFrom-SecureString
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($OutputPath, $encrypted, $utf8NoBom)
    Write-LMOK "API key saved (DPAPI user-scope): $OutputPath"
}

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

Export-ModuleMember -Function Get-LMClaudeConfigPath,
                              Set-LMClaudeConfigProfileA,
                              Set-LMClaudeConfigProfileB,
                              New-LMMcpRemoteBat,
                              Protect-LMClientApiKey
