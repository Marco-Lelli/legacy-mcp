<#
.SYNOPSIS
    LegacyMCP unified setup script.
.DESCRIPTION
    Installs, configures, repairs, or uninstalls LegacyMCP for the
    specified deployment profile. Replaces Install-LegacyMCP.ps1,
    Uninstall-LegacyMCP.ps1, Setup-LegacyMCPClient.ps1, and
    Config-LegacyMCP.ps1.
.PARAMETER Profile
    Deployment profile: A, B-core, B-enterprise, C
.PARAMETER Role
    Machine role (Profile B/C only): Server, Client
.PARAMETER Mode
    Operation mode: Install (default), Configure, Repair, Uninstall
.PARAMETER Gui
    Show GUI wizard instead of CLI prompts (Phase 5 -- not yet implemented)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('A','B-core','B-enterprise','C')]
    [string]$Profile,

    [ValidateSet('Server','Client')]
    [string]$Role,

    [ValidateSet('Install','Configure','Repair','Uninstall')]
    [string]$Mode = 'Install',

    # Profile A -- optional overrides
    [string]$InstallPath,
    [string]$ConfigPath,
    [string]$DataPath,

    # Profile B Server -- optional overrides
    [string]$SnapshotPath,
    [string]$LogPath,
    [string]$ServiceAccount,
    [string]$ApiKey,
    [int]$Port = 8000,
    [string]$CertFile,
    [string]$CertKeyFile,

    # Profile B Client -- mandatory
    [string]$ServerUrl,
    [string]$CaCertPath,

    # GUI (Phase 5)
    [switch]$Gui
)

$ErrorActionPreference = 'Stop'
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesDir = Join-Path $ScriptDir 'modules'
$RepoRoot   = Split-Path $ScriptDir -Parent

Import-Module (Join-Path $ModulesDir 'LegacyMCP.Common.psm1')  -Force
Import-Module (Join-Path $ModulesDir 'LegacyMCP.Python.psm1')  -Force
Import-Module (Join-Path $ModulesDir 'LegacyMCP.Service.psm1') -Force
Import-Module (Join-Path $ModulesDir 'LegacyMCP.Certs.psm1')   -Force
Import-Module (Join-Path $ModulesDir 'LegacyMCP.Config.psm1')  -Force
Import-Module (Join-Path $ModulesDir 'LegacyMCP.Client.psm1')  -Force

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

if ($Gui) { throw 'GUI mode is not yet implemented (Phase 5).' }

if ($Profile -in @('B-core','B-enterprise','C') -and -not $Role) {
    throw "-Role is required for Profile $Profile. Use -Role Server or -Role Client."
}
if ($Profile -eq 'A' -and $Role) {
    throw '-Role is not applicable for Profile A.'
}
if ($Profile -like 'B*' -and $Role -eq 'Server' -and $Mode -eq 'Install' -and -not $ServiceAccount) {
    throw '-ServiceAccount is required for Profile B Server installation.'
}
if ($Profile -like 'B*' -and $Role -eq 'Client' -and $Mode -eq 'Install') {
    if (-not $ServerUrl)  { throw '-ServerUrl is required for Profile B Client installation.' }
    if (-not $CaCertPath) { throw '-CaCertPath is required for Profile B Client installation.' }
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------

if ($Profile -like 'B*' -or $Profile -eq 'C') {
    Assert-LMElevation -Context "Profile $Profile $Mode"
}
if ($Profile -eq 'A' -and (Test-LMElevation)) {
    throw ('Profile A setup must NOT run as Administrator. ' +
           'Running elevated would create the virtual environment and config ' +
           'in the Administrator profile, making them invisible to Claude Desktop.')
}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$VERSION      = '0.2.3'
$SERVICE_NAME = 'LegacyMCP'
$REG_ROOT     = if ($Profile -eq 'A') { 'HKCU:\SOFTWARE\LegacyMCP' } else { 'HKLM:\SOFTWARE\LegacyMCP' }

# ===========================================================================
# PROFILE A
# ===========================================================================

if ($Profile -eq 'A') {

    if ($Mode -eq 'Install') {

        Write-LMStep 'LegacyMCP Setup -- Profile A'

        # Profile A: user-scoped paths -- ProgramFiles/ProgramData require elevation (P6)
        if (-not $InstallPath) { $InstallPath = "$env:LOCALAPPDATA\LegacyMCP" }
        if (-not $ConfigPath)  { $ConfigPath  = "$env:LOCALAPPDATA\LegacyMCP\config\config.yaml" }
        if (-not $DataPath)    { $DataPath    = "$env:USERPROFILE\Documents\LegacyMCP-Data" }
        $VenvPath = Join-Path $InstallPath '.venv'

        Write-LMStep 'Step 1 -- Python'
        $pythonExe = Find-LMPython
        Write-LMOK "Python found: $pythonExe"

        Write-LMStep 'Step 2 -- Directories'
        foreach ($dir in @($InstallPath, (Split-Path $ConfigPath -Parent), $DataPath)) {
            if (-not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Write-LMOK "Created: $dir"
            }
        }

        Write-LMStep 'Step 3 -- Virtual environment'
        New-LMVenv -PythonExe $pythonExe -VenvPath $VenvPath
        $venvPython = Join-Path $VenvPath 'Scripts\python.exe'

        Write-LMStep 'Step 4 -- Package installation'
        Install-LMPackage -VenvPath $VenvPath -PackageOrPath $RepoRoot -Editable

        Write-LMStep 'Step 5 -- Configuration'
        $templatePath = Join-Path $RepoRoot 'config\config.example-A.yaml'
        if (Test-Path $ConfigPath) {
            Write-LMWarn "config.yaml already exists at: $ConfigPath"
            $answer = Read-Host 'Overwrite? [y/N]'
            if ($answer -eq 'y' -or $answer -eq 'Y') {
                Copy-Item $templatePath $ConfigPath -Force
                Write-LMOK 'config.yaml overwritten from template.'
            } else {
                Write-LMInfo 'Existing config.yaml preserved.'
            }
        } else {
            Copy-Item $templatePath $ConfigPath -Force
            Write-LMOK 'config.yaml created from template.'
        }

        Write-LMStep 'Step 6 -- Claude Desktop configuration'
        $claudeConfigPath = Get-LMClaudeConfigPath
        try {
            Set-LMClaudeConfigProfileA -PythonExe $venvPython -ClaudeConfigPath $claudeConfigPath
        } catch {
            Write-LMWarn "Could not write claude_desktop_config.json: $_"
            Write-LMInfo "Add this entry manually under ""mcpServers"" in: $claudeConfigPath"
            Write-LMInfo "  ""legacymcp"": { ""command"": ""$venvPython"", ""args"": [""-m"", ""legacy_mcp.server""] }"
        }

        Write-LMStep 'Step 7 -- Registry'
        try {
            Set-LMRegistry -Key $REG_ROOT -Name 'InstallPath' -Value $InstallPath
            Set-LMRegistry -Key $REG_ROOT -Name 'ConfigPath'  -Value $ConfigPath
            Set-LMRegistry -Key $REG_ROOT -Name 'Profile'     -Value 'A'
            Set-LMRegistry -Key $REG_ROOT -Name 'Transport'   -Value 'stdio'
            Set-LMRegistry -Key $REG_ROOT -Name 'Version'     -Value $VERSION
            Write-LMOK 'Registry entries written.'
        } catch {
            Write-LMWarn "Could not write registry entries: $_"
            Write-LMInfo 'This is non-blocking for Profile A.'
        }

        Write-LMStep 'Setup complete'
        Write-LMOK  'Profile A installation successful.'
        Write-LMInfo "Python:        $venvPython"
        Write-LMInfo "Config:        $ConfigPath"
        Write-LMInfo "Data folder:   $DataPath"
        Write-LMInfo "Claude config: $claudeConfigPath"
        Write-Host ''
        Write-LMInfo 'NEXT STEP: restart Claude Desktop to activate LegacyMCP.'
        Write-Host ''
        Write-LMInfo 'To add AD forests to your workspace, use Manage-Workspaces.ps1:'
        Write-LMInfo "  .\Manage-Workspaces.ps1 -Add -Name 'contoso.local' -File 'C:\path\to\data.json'"
        Write-LMInfo '  See: docs\getting-started-a.md'

    } elseif ($Mode -eq 'Uninstall') {

        Write-LMStep 'LegacyMCP Uninstall -- Profile A'

        $cfg         = Get-LMConfig -RegistryRoot $REG_ROOT
        $InstallPath = if ($InstallPath) { $InstallPath } elseif ($cfg['InstallPath']) { $cfg['InstallPath'] } else { "$env:LOCALAPPDATA\LegacyMCP" }
        $ConfigPath  = if ($ConfigPath)  { $ConfigPath }  elseif ($cfg['ConfigPath'])  { $cfg['ConfigPath'] }  else { "$env:LOCALAPPDATA\LegacyMCP\config\config.yaml" }
        $VenvPath    = Join-Path $InstallPath '.venv'

        try {
            Remove-LMRegistry -Key $REG_ROOT
            Write-LMOK 'Registry entries removed.'
        } catch {
            Write-LMWarn "Could not remove registry entries (non-blocking): $_"
        }

        Write-LMStep 'Uninstall complete'
        Write-LMOK  'Profile A registry entries removed.'
        Write-LMInfo 'To complete uninstall, remove manually:'
        Write-LMInfo "  Venv:   $VenvPath"
        Write-LMInfo "  Config: $ConfigPath"
        Write-LMInfo 'Remove the "legacymcp" entry from claude_desktop_config.json if present.'

    } else {
        throw "Mode '$Mode' is not yet implemented for Profile A."
    }

# ===========================================================================
# PROFILE B SERVER
# ===========================================================================

} elseif ($Profile -like 'B*' -and $Role -eq 'Server') {

    if ($Mode -eq 'Install') {

        Write-LMStep "LegacyMCP Setup -- Profile $Profile Server"

        if (-not $InstallPath)  { $InstallPath  = "$env:ProgramFiles\LegacyMCP" }
        if (-not $ConfigPath)   { $ConfigPath   = "$env:ProgramData\LegacyMCP\config\config.yaml" }
        if (-not $LogPath)      { $LogPath      = "$env:ProgramData\LegacyMCP\logs" }
        if (-not $SnapshotPath) { $SnapshotPath = "$env:ProgramData\LegacyMCP\snapshots" }
        $CertDir  = "$env:ProgramData\LegacyMCP\certs"
        $NssmExe  = Join-Path $ScriptDir 'tools\nssm.exe'
        $VenvPath = Join-Path $InstallPath '.venv'

        Write-LMStep 'Step 1 -- Python'
        $pythonExe = Find-LMPython
        Write-LMOK "Python found: $pythonExe"

        Write-LMStep 'Step 2 -- Virtual environment'
        New-LMVenv -PythonExe $pythonExe -VenvPath $VenvPath
        $venvPython = Join-Path $VenvPath 'Scripts\python.exe'

        Write-LMStep 'Step 3 -- Package installation'
        Install-LMPackage -VenvPath $VenvPath -PackageOrPath $RepoRoot -Editable

        Write-LMStep 'Step 4 -- Directories'
        foreach ($dir in @($InstallPath, (Split-Path $ConfigPath -Parent), $LogPath, $SnapshotPath, $CertDir)) {
            if (-not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Write-LMOK "Created: $dir"
            }
        }

        Write-LMStep 'Step 5 -- TLS certificate'
        if ($CertFile -and $CertKeyFile) {
            $certResult = Import-LMCert -CertFile $CertFile -CertKeyFile $CertKeyFile -CertDir $CertDir
        } else {
            $hostname   = $env:COMPUTERNAME
            $certResult = New-LMSelfSignedCert -VenvPython $venvPython -CertDir $CertDir -Hostname $hostname
        }

        Write-LMStep 'Step 6 -- API key'
        if (-not $ApiKey) { $ApiKey = New-LMApiKey }
        Protect-LMApiKey -ApiKey $ApiKey -ServiceAccount $ServiceAccount -RegistryRoot $REG_ROOT
        Write-LMInfo 'API key stored (DPAPI-NG, SID-scoped). Keep a secure copy if needed.'
        $ApiKey = $null

        Write-LMStep 'Step 7 -- Configuration'
        $templatePath = Join-Path $RepoRoot 'config\config.example-B.yaml'
        if (Test-Path $ConfigPath) {
            Write-LMWarn "config.yaml already exists at: $ConfigPath"
            $answer = Read-Host 'Overwrite? [y/N]'
            if ($answer -eq 'y' -or $answer -eq 'Y') {
                Copy-Item $templatePath $ConfigPath -Force
                Write-LMOK 'config.yaml overwritten from template.'
            } else {
                Write-LMInfo 'Existing config.yaml preserved.'
            }
        } else {
            Copy-Item $templatePath $ConfigPath -Force
            Write-LMOK 'config.yaml created from template.'
        }
        # Write ConfigPath to registry now so Set-LMConfig can find it for SnapshotPath
        Set-LMRegistry -Key $REG_ROOT -Name 'ConfigPath' -Value $ConfigPath
        # Update SSL cert paths in config.yaml
        Invoke-LMReplaceCert -CertFile $certResult.CertFile -CertKeyFile $certResult.KeyFile `
            -CertDir $CertDir -ConfigPath $ConfigPath

        Write-LMStep 'Step 8 -- EventLog'
        Register-LMEventLog

        Write-LMStep 'Step 9 -- Windows service'
        Install-LMService -NssmExe $NssmExe -ServiceName $SERVICE_NAME `
            -PythonExe $venvPython -ConfigPath $ConfigPath `
            -InstallPath $InstallPath -LogPath $LogPath `
            -ServiceAccount $ServiceAccount -Port $Port
        # SnapshotPath after service install so icacls can grant to service account
        Set-LMConfig -RegistryRoot $REG_ROOT -Name 'SnapshotPath' -Value $SnapshotPath

        Write-LMStep 'Step 10 -- Firewall'
        Add-LMFirewallRule -Port $Port

        Write-LMStep 'Step 11 -- Registry'
        Set-LMRegistry -Key $REG_ROOT -Name 'InstallPath'  -Value $InstallPath
        Set-LMRegistry -Key $REG_ROOT -Name 'LogPath'      -Value $LogPath
        Set-LMRegistry -Key $REG_ROOT -Name 'Profile'      -Value $Profile
        Set-LMRegistry -Key $REG_ROOT -Name 'Transport'    -Value 'streamable-http'
        Set-LMRegistry -Key $REG_ROOT -Name 'Port'         -Value $Port -Type 'DWord'
        Set-LMRegistry -Key $REG_ROOT -Name 'Version'      -Value $VERSION
        Write-LMOK 'Registry entries written.'

        Write-LMStep 'Step 12 -- Start service'
        Start-Service -Name $SERVICE_NAME
        Write-LMOK "Service '$SERVICE_NAME' started."

        Write-LMStep 'Setup complete'
        Write-LMOK  "Profile $Profile Server installation successful."
        Write-LMInfo "Service:       $SERVICE_NAME (Running)"
        Write-LMInfo "Install path:  $InstallPath"
        Write-LMInfo "Config:        $ConfigPath"
        Write-LMInfo "Snapshots:     $SnapshotPath"
        Write-LMInfo "Logs:          $LogPath"
        Write-LMInfo "Port:          $Port"
        Write-LMInfo "Certificate:   $($certResult.CertFile)"
        Write-Host ''
        Write-LMWarn 'Copy the CA certificate to the consultant PC:'
        Write-LMWarn "  $($certResult.CertFile)"
        Write-Host ''
        Write-LMInfo 'NEXT STEP: on the consultant PC, run:'
        Write-LMInfo "  .\Setup-LegacyMCP.ps1 -Profile $Profile -Role Client -Mode Install"
        Write-LMInfo "    -ServerUrl https://$($env:COMPUTERNAME):$Port/mcp"
        Write-LMInfo '    -CaCertPath <path-to-copied-server.crt>'
        Write-Host ''
        Write-LMInfo 'To configure forests, use Manage-Workspaces.ps1:'
        Write-LMInfo "  .\Manage-Workspaces.ps1 -Add -Name 'contoso.local' -DC 'dc01.contoso.local'"
        Write-LMInfo '  See: docs\getting-started-b-core.md'

    } elseif ($Mode -eq 'Uninstall') {

        Write-LMStep "LegacyMCP Uninstall -- Profile $Profile Server"

        $cfg         = Get-LMConfig -RegistryRoot $REG_ROOT
        $InstallPath = if ($InstallPath) { $InstallPath } elseif ($cfg['InstallPath']) { $cfg['InstallPath'] } else { "$env:ProgramFiles\LegacyMCP" }
        $ConfigPath  = if ($ConfigPath)  { $ConfigPath }  elseif ($cfg['ConfigPath'])  { $cfg['ConfigPath'] }  else { "$env:ProgramData\LegacyMCP\config\config.yaml" }
        $LogPath     = if ($LogPath)     { $LogPath }     elseif ($cfg['LogPath'])     { $cfg['LogPath'] }     else { "$env:ProgramData\LegacyMCP\logs" }
        $SnapshotPath = if ($SnapshotPath) { $SnapshotPath } elseif ($cfg['SnapshotPath']) { $cfg['SnapshotPath'] } else { "$env:ProgramData\LegacyMCP\snapshots" }
        $NssmExe     = Join-Path $ScriptDir 'tools\nssm.exe'

        Write-LMStep 'Step 1 -- Stop and remove service'
        Uninstall-LMService -NssmExe $NssmExe -ServiceName $SERVICE_NAME

        Write-LMStep 'Step 2 -- Firewall rule'
        Remove-LMFirewallRule

        Write-LMStep 'Step 3 -- EventLog'
        Unregister-LMEventLog

        Write-LMStep 'Step 4 -- Registry'
        try {
            Remove-LMRegistry -Key $REG_ROOT
            Write-LMOK 'Registry entries removed.'
        } catch {
            Write-LMWarn "Could not remove registry entries: $_"
        }

        Write-LMStep 'Uninstall complete'
        Write-LMOK  "Profile $Profile Server uninstalled."
        Write-LMWarn 'Data files preserved -- delete securely when no longer needed:'
        Write-LMInfo "  Config:    $ConfigPath"
        Write-LMInfo "  Logs:      $LogPath"
        Write-LMInfo "  Snapshots: $SnapshotPath"

    } else {
        throw "Mode '$Mode' is not yet implemented for Profile $Profile Server."
    }

# ===========================================================================
# PROFILE B CLIENT
# ===========================================================================

} elseif ($Profile -like 'B*' -and $Role -eq 'Client') {

    if ($Mode -eq 'Install') {

        Write-LMStep "LegacyMCP Setup -- Profile $Profile Client"

        $ClientPath    = "$env:LOCALAPPDATA\LegacyMCP"
        $ClientCertDir = "$env:LOCALAPPDATA\LegacyMCP\certs"
        $Ps1Path       = Join-Path $RepoRoot 'client\mcp-remote-live.ps1'

        foreach ($dir in @($ClientPath, $ClientCertDir)) {
            if (-not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Write-LMOK "Created: $dir"
            }
        }

        Write-LMStep 'Step 1 -- CA certificate'
        if (-not (Test-Path $CaCertPath)) { throw "CA certificate not found: $CaCertPath" }
        $localCertPath = Join-Path $ClientCertDir (Split-Path $CaCertPath -Leaf)
        Copy-Item -Path $CaCertPath -Destination $localCertPath -Force
        Write-LMOK "CA certificate copied to: $localCertPath"
        Write-LMInfo 'NODE_EXTRA_CA_CERTS will be set in the BAT entry point.'

        Write-LMStep 'Step 2 -- API key'
        $keyPath     = Join-Path $ClientPath '.legacymcp-key'
        $apiKeyInput = Read-Host "Enter the API key for $ServerUrl" -AsSecureString
        $bstr        = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($apiKeyInput)
        try {
            $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            Protect-LMClientApiKey -ApiKey $plainKey -OutputPath $keyPath
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            $plainKey = $null
        }

        Write-LMStep 'Step 3 -- BAT entry point'
        $batPath = Join-Path $ClientPath 'mcp-remote-live.bat'
        New-LMMcpRemoteBat -ServerUrl $ServerUrl -CertPath $localCertPath `
            -Ps1Path $Ps1Path -OutputPath $batPath

        Write-LMStep 'Step 4 -- Claude Desktop configuration'
        $claudeConfigPath = Get-LMClaudeConfigPath
        Set-LMClaudeConfigProfileB -BatPath $batPath -ClaudeConfigPath $claudeConfigPath

        Write-LMStep 'Setup complete'
        Write-LMOK  "Profile $Profile Client installation successful."
        Write-LMInfo "API key:       $keyPath"
        Write-LMInfo "BAT:           $batPath"
        Write-LMInfo "CA cert:       $localCertPath"
        Write-LMInfo "Claude config: $claudeConfigPath"
        Write-Host ''
        Write-LMInfo 'NEXT STEP: restart Claude Desktop to activate LegacyMCP.'

    } elseif ($Mode -eq 'Uninstall') {

        Write-LMStep "LegacyMCP Uninstall -- Profile $Profile Client"

        $ClientPath       = "$env:LOCALAPPDATA\LegacyMCP"
        $claudeConfigPath = Get-LMClaudeConfigPath

        # Remove client directory with confirmation
        if (Test-Path $ClientPath) {
            Write-LMWarn "This will permanently delete: $ClientPath"
            $answer = Read-Host 'Proceed? [y/N]'
            if ($answer -eq 'y' -or $answer -eq 'Y') {
                Remove-Item $ClientPath -Recurse -Force
                Write-LMOK "Removed: $ClientPath"
            } else {
                Write-LMInfo "Skipped removal of $ClientPath"
            }
        } else {
            Write-LMInfo "Client directory not found -- skipping: $ClientPath"
        }

        # Remove legacymcp-live from claude_desktop_config.json
        if (Test-Path $claudeConfigPath) {
            try {
                $rawJson = Get-Content $claudeConfigPath -Raw -Encoding UTF8
                $config  = $rawJson | ConvertFrom-Json
                $mcpServers = $config.PSObject.Properties['mcpServers'].Value
                if ($mcpServers -and $mcpServers.PSObject.Properties['legacymcp-live']) {
                    $backupPath = "$claudeConfigPath.bak"
                    Copy-Item $claudeConfigPath $backupPath -Force
                    $mcpServers.PSObject.Properties.Remove('legacymcp-live')
                    $updatedJson = $config | ConvertTo-Json -Depth 10
                    [System.IO.File]::WriteAllText(
                        $claudeConfigPath,
                        $updatedJson,
                        (New-Object System.Text.UTF8Encoding $false)
                    )
                    Write-LMOK "Removed 'legacymcp-live' from claude_desktop_config.json"
                } else {
                    Write-LMInfo "'legacymcp-live' entry not found -- skipping."
                }
            } catch {
                Write-LMWarn "Could not update claude_desktop_config.json: $_"
                Write-LMInfo "Remove 'legacymcp-live' manually from: $claudeConfigPath"
            }
        }

        Write-LMStep 'Uninstall complete'
        Write-LMOK  "Profile $Profile Client uninstalled."

    } else {
        throw "Mode '$Mode' is not yet implemented for Profile $Profile Client."
    }

# ===========================================================================
# PROFILE C
# ===========================================================================

} else {
    throw "Profile $Profile is not yet fully implemented. Refer to docs\deployment-profiles.md."
}
