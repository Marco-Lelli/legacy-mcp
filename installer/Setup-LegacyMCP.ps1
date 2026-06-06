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
    Launch the interactive setup wizard instead of CLI prompts. Covers Install, Configure and Uninstall for Profile A and B-core.
.PARAMETER Version
    Optional. Install a specific version from PyPI (e.g. -Version 0.2.2).
    Use this when a newer version introduces a regression or an unwanted
    behavior change. Has no effect when -DevInstall is specified.
.PARAMETER RotateApiKey
    Generate and store a new API key. The new key is printed to the
    console for client reconfiguration. All existing clients must be
    updated with the new key. Use in -Mode Configure only.
.PARAMETER RotateCert
    Generate a new self-signed TLS certificate and key. The new certificate
    must be distributed to all clients. Use in -Mode Configure only.
#>
[CmdletBinding()]
param(
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
    [string]$ApiKey = "",
    [int]$Port = 8000,
    [string]$CertFile,
    [string]$CertKeyFile,
    [switch]$DevInstall,

    # Profile B Client -- mandatory
    [string]$ServerUrl,
    [string]$CaCertPath,

    # Purge -- remove registry and ProgramData on Uninstall
    [switch]$Purge,

    # GUI (Phase 5)
    [switch]$Gui,

    [string]$Version = "",

    [switch]$RotateApiKey,

    [switch]$RotateCert,

    # Passed internally by the GUI wizard for non-gMSA service accounts
    [SecureString]$ServiceAccountPassword = $null
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
$INSTALLER_VERSION = '0.2.3'
Import-Module (Join-Path $ModulesDir 'LegacyMCP.Gui.psm1')       -Force -WarningAction SilentlyContinue
Import-Module (Join-Path $ModulesDir 'LegacyMCP.Gui.Steps.psm1') -Force -WarningAction SilentlyContinue
Import-Module (Join-Path $ModulesDir 'LegacyMCP.Gui.Exec.psm1')  -Force -WarningAction SilentlyContinue

# ---------------------------------------------------------------------------
# GUI wizard -- must run before all validation (wizard collects its own params)
# ---------------------------------------------------------------------------

if ($Gui) {
    $wizardResult = Start-LMWizard `
        -ModulesDir     $ModulesDir `
        -ScriptDir      $ScriptDir `
        -RepoRoot       $RepoRoot `
        -ScriptPath     $MyInvocation.MyCommand.Path `
        -WizardVersion  $INSTALLER_VERSION
    if ($wizardResult) { exit 0 } else { exit 1 }
}

if ([string]::IsNullOrEmpty($Profile)) {
    throw "-Profile is required. Specify: -Profile A, B-core, B-enterprise, or C. Use -Gui for the interactive wizard."
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

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
if ($ApiKey -and $ApiKey.Length -lt 16) {
    Write-Error "Setup-LegacyMCP: -ApiKey is too short (minimum 16 characters)"
    exit 1
}
if ($Purge -and $Mode -ne 'Uninstall') {
    Write-Error "Setup-LegacyMCP: -Purge can only be used with -Mode Uninstall"
    exit 1
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------

if (($Profile -like 'B*' -and $Role -eq 'Server') -or $Profile -eq 'C') {
    Assert-LMElevation -Context "Profile $Profile $Mode"
}
if ($Profile -eq 'A' -and (Test-LMElevation)) {
    throw ('Profile A setup must NOT run as Administrator. ' +
           'Running elevated would create the virtual environment and config ' +
           'in the Administrator profile, making them invisible to Claude Desktop.')
}
if ($Profile -like 'B*' -and $Role -eq 'Client' -and (Test-LMElevation)) {
    throw 'Do not run as Administrator. Run as the normal user account whose Claude Desktop you are configuring.'
}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

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
                try {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                } catch {
                    Write-Error "Setup: Failed to create directory '$dir': $_"
                    exit 1
                }
                Write-LMOK "Created: $dir"
            }
        }

        Write-LMStep 'Step 3 -- Virtual environment'
        New-LMVenv -PythonExe $pythonExe -VenvPath $VenvPath
        $venvPython = Join-Path $VenvPath 'Scripts\python.exe'

        Write-LMStep 'Step 4 -- Package installation'
        $installMode = if ($DevInstall) { 'dev' } else { 'release' }
        if ($DevInstall) {
            if ($Version -ne '') {
                Write-LMWarn '-Version has no effect in DevInstall mode. The local source tree is used.'
            }
            if (-not (Test-Path (Join-Path $RepoRoot 'pyproject.toml'))) {
                Write-Error "Setup-LegacyMCP: -DevInstall requires a source tree (pyproject.toml not found at: $RepoRoot)"
                exit 1
            }
            try {
                Install-LMPackage -VenvPath $VenvPath -PackageOrPath $RepoRoot -Editable
            } catch {
                Write-Error "Setup-LegacyMCP: pip install failed (mode: dev): $_"
                exit 1
            }
        } else {
            $pipPackage = if ($Version -ne '') { "legacy-mcp==$Version" } else { 'legacy-mcp' }
            try {
                Install-LMPackage -VenvPath $VenvPath -PackageOrPath $pipPackage
            } catch {
                Write-Error "Setup-LegacyMCP: pip install failed (mode: release): $_"
                exit 1
            }
        }
        $InstalledVersion = $null
        if ($DevInstall) {
            try {
                $gitHash = & git -C $RepoRoot rev-parse --short HEAD 2>&1
                if ($LASTEXITCODE -eq 0 -and $gitHash) {
                    $InstalledVersion = "dev-$($gitHash.ToString().Trim())"
                }
            } catch {}
            if (-not $InstalledVersion) { $InstalledVersion = 'dev-unknown' }
        } else {
            try {
                $pipOut = & (Join-Path $VenvPath 'Scripts\python.exe') -m pip show legacy-mcp 2>&1
                $verLine = $pipOut | Select-String '^Version:' | Select-Object -First 1
                if ($verLine) { $InstalledVersion = ($verLine.Line -replace 'Version:\s*', '').Trim() }
            } catch {}
            if (-not $InstalledVersion) { $InstalledVersion = $INSTALLER_VERSION }
        }
        Write-LMInfo "Package installed (mode: $installMode, version: $InstalledVersion)."

        Write-LMStep 'Step 5 -- Configuration'
        $templatePath = Join-Path $RepoRoot 'config\config.example-A.yaml'
        if (-not (Test-Path $templatePath)) {
            Write-Error "Setup: Config template not found: $templatePath"
            exit 1
        }
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
            Set-LMRegistry -Key $REG_ROOT -Name 'Version'     -Value $INSTALLER_VERSION
            Set-LMRegistry -Key $REG_ROOT -Name 'InstalledVersion' -Value $InstalledVersion
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
        $CertDir    = "$env:ProgramData\LegacyMCP\certs"
        $NssmSource = Join-Path $ScriptDir 'tools\nssm.exe'
        $NssmExe    = Join-Path $InstallPath 'nssm.exe'
        $VenvPath   = Join-Path $InstallPath '.venv'
        $installMode = if ($DevInstall) { 'dev' } else { 'release' }

        if ((Test-Path $REG_ROOT) -and (Test-Path $VenvPath)) {
            $existingMode = (Get-ItemProperty -Path $REG_ROOT `
                -ErrorAction SilentlyContinue).InstallMode
            if ($existingMode -and $existingMode -ne $installMode) {
                Write-Error ("Setup: Cannot switch InstallMode from '$existingMode'" +
                    " to '$installMode' while the existing venv is still present.`n" +
                    "Run uninstall first to remove the venv:`n" +
                    "  .\Setup-LegacyMCP.ps1 -Profile $Profile -Role Server -Mode Uninstall`n" +
                    "Then reinstall with the desired mode.")
                exit 1
            }
        }

        $existingVersion = $null
        if (Test-Path $REG_ROOT) {
            $existingProps = Get-ItemProperty -Path $REG_ROOT `
                -ErrorAction SilentlyContinue
            $existingVersion = if ($existingProps -and $existingProps.InstalledVersion) {
                $existingProps.InstalledVersion
            } else {
                'unknown (pre-v0.2.4)'
            }
        }
        $keepCredentials = $false
        if ($existingVersion) {
            Write-LMWarn "[!] Existing LegacyMCP installation detected (version: $existingVersion)"
            Write-Host ''
            Write-LMInfo '    API key and certificate found on this machine.'
            Write-LMInfo '    Do you want to keep existing credentials?'
            Write-LMInfo '    Existing clients will continue to work without reconfiguration.'
            Write-Host ''
            Write-LMInfo '    [K] Keep existing credentials (recommended)'
            Write-LMInfo '    [R] Regenerate all credentials (clients will need reconfiguration)'
            Write-Host ''
            $choice = Read-Host 'Choice [K/R] (default: K)'
            if ([string]::IsNullOrWhiteSpace($choice)) { $choice = 'K' }
            $keepCredentials = ($choice.ToUpper() -eq 'K')
        }

        # Check service state -- only when reinstalling over existing installation
        $serviceWasRunning = $false
        if ($existingVersion) {
            $svc = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
            if ($svc) {
                if ($svc.Status -eq 'Running') {
                    Write-Host ''
                    Write-LMWarn "Service '$SERVICE_NAME' is currently running."
                    Write-LMInfo "  It must be stopped before reinstalling."
                    $stopChoice = Read-Host "Stop service and proceed? [y/N]"
                    if ($stopChoice.ToLower() -ne 'y') {
                        Write-Error ("Setup: Reinstall aborted -- service '$SERVICE_NAME' " +
                            "is running and stop was not confirmed.`n" +
                            "Stop the service manually and re-run the installer.")
                        exit 1
                    }
                    try {
                        Stop-Service -Name $SERVICE_NAME -Force -ErrorAction Stop
                        Write-LMOK "Service '$SERVICE_NAME' stopped."
                        $serviceWasRunning = $true
                    } catch {
                        Write-Error ("Setup: Failed to stop service '$SERVICE_NAME': $_`n" +
                            "Stop it manually (Stop-Service $SERVICE_NAME -Force " +
                            "or Task Manager) and re-run the installer.")
                        exit 1
                    }
                } elseif ($svc.Status -ne 'Stopped') {
                    Write-Error ("Setup: Service '$SERVICE_NAME' is in an unexpected " +
                        "state ('$($svc.Status)').`n" +
                        "Wait for the service to reach a stable state (Running or " +
                        "Stopped) and re-run the installer.")
                    exit 1
                }
                # Status -eq 'Stopped': proceed silently, no action needed
            }
            # Service not found: fresh reinstall scenario, proceed normally
        }

        Write-LMStep 'Step 1 -- Python'
        $pythonExe = Find-LMPython

        $pythonExeLower = $pythonExe.ToLower()
        $appDataLocal   = $env:LOCALAPPDATA.ToLower()
        $appDataRoaming = $env:APPDATA.ToLower()
        if ($pythonExeLower.StartsWith($appDataLocal) -or
            $pythonExeLower.StartsWith($appDataRoaming)) {
            Write-Error (
                "Setup: Python is installed for the current user only " +
                "('$pythonExe').`n" +
                "Profile B Server requires Python installed for all users " +
                "so the service account can access it.`n" +
                "Fix: uninstall Python, then reinstall it selecting " +
                "'Install for all users' in the Python installer.`n" +
                "Typical system-wide path: C:\Program Files\Python3xx\python.exe"
            )
            exit 1
        }
        Write-LMOK "Python found (system-wide): $pythonExe"

        Write-LMStep 'Step 2 -- Virtual environment'
        New-LMVenv -PythonExe $pythonExe -VenvPath $VenvPath
        $venvPython = Join-Path $VenvPath 'Scripts\python.exe'

        Write-LMStep 'Step 3 -- Package installation'
        $installMode = if ($DevInstall) { 'dev' } else { 'release' }
        if ($DevInstall) {
            if ($Version -ne "") {
                Write-LMWarn '-Version has no effect in DevInstall mode. The local source tree is used.'
            }
            if (-not (Test-Path (Join-Path $RepoRoot 'pyproject.toml'))) {
                Write-Error "Setup-LegacyMCP: -DevInstall requires a source tree (pyproject.toml not found at: $RepoRoot)"
                exit 1
            }
            try {
                Install-LMPackage -VenvPath $VenvPath -PackageOrPath $RepoRoot -Editable
            } catch {
                Write-Error "Setup-LegacyMCP: pip install failed (mode: dev): $_"
                exit 1
            }
        } else {
            $pipPackage = if ($Version -ne "") { "legacy-mcp==$Version" } else { "legacy-mcp" }
            try {
                Install-LMPackage -VenvPath $VenvPath -PackageOrPath $pipPackage
            } catch {
                Write-Error "Setup-LegacyMCP: pip install failed (mode: release): $_"
                exit 1
            }
        }
        $InstalledVersion = $null
        if ($DevInstall) {
            try {
                $gitHash = & git -C $RepoRoot rev-parse --short HEAD 2>&1
                if ($LASTEXITCODE -eq 0 -and $gitHash) {
                    $InstalledVersion = "dev-$($gitHash.ToString().Trim())"
                }
            } catch {}
            if (-not $InstalledVersion) { $InstalledVersion = 'dev-unknown' }
        } else {
            try {
                $pipOut = & (Join-Path $VenvPath 'Scripts\python.exe') -m pip show legacy-mcp 2>&1
                $verLine = $pipOut | Select-String '^Version:' | Select-Object -First 1
                if ($verLine) { $InstalledVersion = ($verLine.Line -replace 'Version:\s*', '').Trim() }
            } catch {}
            if (-not $InstalledVersion) { $InstalledVersion = $INSTALLER_VERSION }
        }
        Write-LMInfo "Package installed (mode: $installMode, version: $InstalledVersion)."

        Write-LMStep 'Step 4 -- Directories'
        foreach ($dir in @($InstallPath, (Split-Path $ConfigPath -Parent), $LogPath, $SnapshotPath, $CertDir)) {
            if (-not (Test-Path $dir)) {
                try {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                } catch {
                    Write-Error "Setup: Failed to create directory '$dir': $_"
                    exit 1
                }
                Write-LMOK "Created: $dir"
            }
        }

        if (-not (Test-Path $NssmSource)) {
            Write-Error "Setup: nssm.exe not found in installer tools: $NssmSource"
            exit 1
        }
        try {
            Copy-Item -Path $NssmSource -Destination $NssmExe -Force
            Write-LMOK "nssm.exe copied to: $NssmExe"
        } catch {
            Write-Error "Setup: Failed to copy nssm.exe to '$NssmExe': $_"
            exit 1
        }

        $fqdn = [System.Net.Dns]::GetHostEntry('').HostName

        Write-LMStep 'Step 5 -- TLS certificate'
        $keyPasswordBlob = $null
        if ($keepCredentials) {
            $certResult = @{ CertFile = (Join-Path $CertDir 'server.crt'); KeyFile = (Join-Path $CertDir 'server.key') }
            Write-LMOK 'Existing TLS certificate preserved.'
        } elseif ($CertFile -and $CertKeyFile) {
            $certResult = Import-LMCert -CertFile $CertFile -CertKeyFile $CertKeyFile -CertDir $CertDir
        } else {
            $certResult = New-LMSelfSignedCert -VenvPython $venvPython -CertDir $CertDir -Hostname $fqdn
            if ($certResult.KeyPassword) {
                try {
                    $keyPasswordBlob = Protect-LMKeyPasswordBlob `
                        -PlainText $certResult.KeyPassword `
                        -ServiceAccount $ServiceAccount
                    Write-LMOK 'TLS key password encrypted (DPAPI-NG, SID-scoped).'
                } catch {
                    Write-Error "Setup: Failed to encrypt TLS key password: $_"
                    exit 1
                }
                $certResult.KeyPassword = $null
                [System.GC]::Collect()
            }
        }

        Write-LMStep 'Step 6 -- API key'
        if ($ApiKey) {
            $displayApiKey = $ApiKey
            Protect-LMApiKey -ApiKey $ApiKey -ServiceAccount $ServiceAccount -RegistryRoot $REG_ROOT
            Write-LMInfo 'API key stored (DPAPI-NG, SID-scoped). Provided via -ApiKey parameter.'
            $ApiKey = $null
        } elseif ($keepCredentials) {
            $displayApiKey = $null
            Write-LMOK 'API key preserved (existing DPAPI-NG entry retained).'
        } else {
            $newApiKey = New-LMApiKey
            $displayApiKey = $newApiKey
            Protect-LMApiKey -ApiKey $newApiKey -ServiceAccount $ServiceAccount -RegistryRoot $REG_ROOT
            Write-LMInfo 'API key stored (DPAPI-NG, SID-scoped). Keep a secure copy if needed.'
            $newApiKey = $null
        }

        Write-LMStep 'Step 7 -- Configuration'
        $templatePath = Join-Path $RepoRoot 'config\config.example-B.yaml'
        if (-not (Test-Path $templatePath)) {
            Write-Error "Setup: Config template not found: $templatePath"
            exit 1
        }
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
        try {
            Set-LMRegistry -Key $REG_ROOT -Name 'ConfigPath' -Value $ConfigPath
        } catch {
            Write-Error "Setup: Failed to write ConfigPath to registry '$REG_ROOT': $_"
            exit 1
        }
        # Update SSL cert paths in config.yaml.
        # Both Import-LMCert (user-provided) and New-LMSelfSignedCert already place the
        # cert in $CertDir -- only the YAML update is needed here. Invoke-LMReplaceCert
        # would call Import-LMCert again, causing "overwrite with itself" on PS 5.1.
        Update-LMYamlSslFields -YamlPath $ConfigPath `
            -SslCertFile $certResult.CertFile -SslKeyFile $certResult.KeyFile `
            -VenvPython $venvPython
        Write-LMOK 'ssl_certfile and ssl_keyfile updated in config.yaml.'
        Update-LMYamlPort -YamlPath $ConfigPath -Port $Port
        Write-LMOK "port updated in config.yaml: $Port"

        Write-LMStep 'Step 8 -- EventLog'
        Register-LMEventLog

        Write-LMStep 'Step 9 -- Windows service'
        Install-LMService -NssmExe $NssmExe -ServiceName $SERVICE_NAME `
            -PythonExe $venvPython -ConfigPath $ConfigPath `
            -InstallPath $InstallPath -LogPath $LogPath `
            -ServiceAccount $ServiceAccount -Port $Port `
            -ServiceAccountPassword $ServiceAccountPassword
        # SnapshotPath after service install so icacls can grant to service account
        try {
            Set-LMConfig -RegistryRoot $REG_ROOT -Name 'SnapshotPath' -Value $SnapshotPath
        } catch {
            Write-Error "Setup: Failed to configure SnapshotPath '$SnapshotPath': $_"
            exit 1
        }

        Write-LMStep 'Step 10 -- Firewall'
        Add-LMFirewallRule -Port $Port

        Write-LMStep 'Step 11 -- Registry'
        try {
            Set-LMRegistry -Key $REG_ROOT -Name 'InstallPath'      -Value $InstallPath
            Set-LMRegistry -Key $REG_ROOT -Name 'LogPath'          -Value $LogPath
            Set-LMRegistry -Key $REG_ROOT -Name 'Profile'          -Value $Profile
            Set-LMRegistry -Key $REG_ROOT -Name 'Transport'        -Value 'streamable-http'
            Set-LMRegistry -Key $REG_ROOT -Name 'Port'             -Value $Port -Type 'DWord'
            Set-LMRegistry -Key $REG_ROOT -Name 'Version'          -Value $INSTALLER_VERSION
            Set-LMRegistry -Key $REG_ROOT -Name 'InstallMode'      -Value $installMode
            Set-LMRegistry -Key $REG_ROOT -Name 'InstalledVersion' -Value $InstalledVersion
            Set-LMRegistry -Key $REG_ROOT -Name 'NssmPath'         -Value $NssmExe
            if ($keyPasswordBlob) {
                Set-LMRegistry -Key $REG_ROOT -Name 'KeyPasswordBlob' -Value $keyPasswordBlob
            }
        } catch {
            Write-Error "Setup: Failed to write registry entries under '$REG_ROOT': $_"
            exit 1
        }
        Write-LMOK 'Registry entries written.'

        Write-LMStep 'Step 12 -- Start service'
        try {
            Start-Service -Name $SERVICE_NAME
            Write-LMOK "Service '$SERVICE_NAME' started."
        } catch {
            Write-Error "Setup: Failed to start service '$SERVICE_NAME': $_"
            exit 1
        }

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
        if ($displayApiKey) {
            Write-LMWarn 'API key (save this -- needed for client setup):'
            Write-LMWarn "  $displayApiKey"
            $displayApiKey = $null
        } else {
            Write-LMInfo 'API key: preserved (clients unchanged).'
        }
        Write-Host ''
        Write-LMWarn 'Copy the CA certificate to the consultant PC:'
        Write-LMWarn "  $($certResult.CertFile)"
        Write-Host ''
        Write-LMInfo 'NEXT STEP: on the consultant PC, run:'
        Write-LMInfo "  .\Setup-LegacyMCP.ps1 -Profile $Profile -Role Client -Mode Install"
        Write-LMInfo "    -ServerUrl https://$($fqdn):$Port/mcp"
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
        $NssmExe  = if ($cfg['NssmPath'] -and (Test-Path $cfg['NssmPath'])) {
            $cfg['NssmPath']
        } elseif (Test-Path (Join-Path $InstallPath 'nssm.exe')) {
            Join-Path $InstallPath 'nssm.exe'
        } else {
            Join-Path $ScriptDir 'tools\nssm.exe'
        }
        $VenvPath = Join-Path $InstallPath '.venv'

        Write-LMStep 'Step 1 -- Stop and remove service'
        Uninstall-LMService -NssmExe $NssmExe -ServiceName $SERVICE_NAME `
            -VenvPath $VenvPath -RegistryRoot $REG_ROOT

        Write-LMStep 'Step 2 -- Firewall rule'
        Remove-LMFirewallRule

        Write-LMStep 'Step 3 -- EventLog'
        Unregister-LMEventLog

        Write-LMStep 'Step 4 -- Binaries'
        if (Test-Path $InstallPath) {
            try {
                Remove-Item $InstallPath -Recurse -Force
                Write-LMOK "Install directory removed: $InstallPath"
            } catch {
                Write-LMWarn "Could not remove '$InstallPath': $_"
                Write-LMInfo "Remove manually: $InstallPath"
            }
        } else {
            Write-LMInfo "Install directory not found (already removed): $InstallPath"
        }

        Write-LMStep 'Step 5 -- Registry'
        Write-LMInfo 'Registry preserved (install state retained for reinstall/upgrade).'

        Write-LMStep 'Step 6 -- Purge'
        if ($Purge) {
            $purgeDataPath = Join-Path $env:ProgramData 'LegacyMCP'
            Write-LMWarn 'This will permanently delete:'
            Write-LMWarn "  Registry: $REG_ROOT"
            Write-LMWarn "  Data:     $purgeDataPath"
            $confirm = Read-Host 'Type YES to confirm purge'
            if ($confirm -eq 'YES') {
                try {
                    Remove-LMRegistry -Key $REG_ROOT
                    Write-LMOK 'Registry entries removed.'
                } catch {
                    Write-LMWarn "Could not remove registry entries: $_"
                }
                if (Test-Path $purgeDataPath) {
                    try {
                        Remove-Item $purgeDataPath -Recurse -Force
                        Write-LMOK "Removed: $purgeDataPath"
                    } catch {
                        Write-LMWarn "Could not remove '$purgeDataPath': $_"
                        Write-LMInfo "Remove manually: $purgeDataPath"
                    }
                } else {
                    Write-LMInfo "Data directory not found (already removed): $purgeDataPath"
                }
            } else {
                Write-LMInfo 'Purge cancelled.'
            }
        } else {
            Write-LMInfo 'Skipped (run with -Purge to remove registry and data).'
        }

        Write-LMStep 'Uninstall complete'
        Write-LMOK  "Profile $Profile Server uninstalled."
        if (-not $Purge) {
            Write-LMInfo 'Registry and data files preserved.'
            Write-LMInfo "  Config:    $ConfigPath"
            Write-LMInfo "  Logs:      $LogPath"
            Write-LMInfo "  Snapshots: $SnapshotPath"
            Write-LMInfo 'To remove all data and configuration:'
            Write-LMInfo "  .\Setup-LegacyMCP.ps1 -Profile $Profile -Role Server -Mode Uninstall -Purge"
        }

    } elseif ($Mode -eq 'Configure') {

        Write-LMStep "LegacyMCP Configure -- Profile $Profile Server"

        $cfg        = Get-LMConfig -RegistryRoot $REG_ROOT
        $InstallPath = if ($InstallPath) { $InstallPath } elseif ($cfg['InstallPath']) { $cfg['InstallPath'] } else { "$env:ProgramFiles\LegacyMCP" }
        $ConfigPath  = if ($ConfigPath)  { $ConfigPath }  elseif ($cfg['ConfigPath'])  { $cfg['ConfigPath'] }  else { "$env:ProgramData\LegacyMCP\config\config.yaml" }
        $CertDir         = "$env:ProgramData\LegacyMCP\certs"
        $venvPython      = Join-Path $InstallPath '.venv\Scripts\python.exe'
        $restartRequired = $false

        Write-LMStep 'Current configuration'
        Test-LMConfig -RegistryRoot $REG_ROOT -Profile $Profile | Out-Null

        if ($CertFile -and $CertKeyFile) {
            Write-LMStep 'Updating TLS certificate'
            if (-not $ServiceAccount) {
                $wmiSvc = $null
                try { $wmiSvc = Get-CimInstance Win32_Service -Filter "Name='LegacyMCP'" -ErrorAction SilentlyContinue } catch {}
                if ($wmiSvc -and $wmiSvc.StartName) { $ServiceAccount = $wmiSvc.StartName }
            }
            $certReplaceResult = Invoke-LMReplaceCert `
                -CertFile $CertFile -CertKeyFile $CertKeyFile `
                -CertDir $CertDir -ConfigPath $ConfigPath `
                -ServiceName $SERVICE_NAME -VenvPython $venvPython
            if ($certReplaceResult.KeyPassword -and $ServiceAccount) {
                try {
                    $keyBlob = Protect-LMKeyPasswordBlob `
                        -PlainText $certReplaceResult.KeyPassword `
                        -ServiceAccount $ServiceAccount
                    Set-LMRegistry -Key $REG_ROOT -Name 'KeyPasswordBlob' -Value $keyBlob
                    Write-LMOK 'TLS key password encrypted and KeyPasswordBlob updated.'
                } catch {
                    Write-LMWarn "Could not update KeyPasswordBlob: $_"
                } finally {
                    $certReplaceResult.KeyPassword = $null
                }
            } elseif ($certReplaceResult.KeyPassword) {
                Write-LMWarn 'KeyPasswordBlob not updated -- service account unknown. Pass -ServiceAccount explicitly.'
                $certReplaceResult.KeyPassword = $null
            }
            $restartRequired = $true
        }

        if ($SnapshotPath -ne '') {
            Write-LMStep 'Updating snapshot path'
            $currentSnapshotPath = $null
            try {
                $cfgVals = Get-LMConfig -RegistryRoot $REG_ROOT
                if ($cfgVals.ContainsKey('SnapshotPath')) {
                    $currentSnapshotPath = $cfgVals['SnapshotPath']
                }
            } catch {}
            if ($currentSnapshotPath) {
                Write-LMInfo "  Current: $currentSnapshotPath"
            }
            Write-LMInfo "  New:     $SnapshotPath"
            Write-LMInfo '  Note: existing snapshot files are not moved.'
            Set-LMConfig -RegistryRoot $REG_ROOT -Name 'SnapshotPath' -Value $SnapshotPath
            $restartRequired = $true
        }

        if ($PSBoundParameters.ContainsKey('Port')) {
            Write-LMStep 'Updating port'
            $currentPort = $null
            try {
                $cfgVals = Get-LMConfig -RegistryRoot $REG_ROOT
                if ($cfgVals.ContainsKey('Port')) { $currentPort = $cfgVals['Port'] }
            } catch {}
            Write-LMWarn "Changing port from $currentPort to $Port will:"
            Write-LMWarn "  - Restart the service (active sessions will be interrupted)"
            Write-LMWarn "  - Require reconfiguration of all clients"
            $confirm = Read-Host 'Change port? [y/N]'
            if ($confirm -notmatch '^[Yy]$') {
                Write-LMInfo 'Port change cancelled.'
            } else {
                Set-LMConfig -RegistryRoot $REG_ROOT -Name 'Port' -Value "$Port"
                Update-LMYamlPort -YamlPath $ConfigPath -Port $Port
                Add-LMFirewallRule -Port $Port
                Write-LMInfo 'Restarting service to apply new port...'
                Restart-Service -Name $SERVICE_NAME -Force
                Write-LMOK "Service restarted on port $Port."
                $restartRequired = $false
            }
        }

        if ($ApiKey) {
            Write-LMStep 'Updating API key'
            if (-not $ServiceAccount) {
                $wmiSvc = $null
                try { $wmiSvc = Get-CimInstance Win32_Service -Filter "Name='LegacyMCP'" -ErrorAction SilentlyContinue } catch {}
                if ($wmiSvc -and $wmiSvc.StartName) { $ServiceAccount = $wmiSvc.StartName }
            }
            if (-not $ServiceAccount) {
                Write-Error 'Setup: -ServiceAccount is required to update the API key in Configure mode.'
                exit 1
            }
            Protect-LMApiKey -ApiKey $ApiKey -ServiceAccount $ServiceAccount -RegistryRoot $REG_ROOT
            Write-LMInfo 'API key updated (DPAPI-NG, SID-scoped).'
            $ApiKey = $null
            $restartRequired = $true
        }

        if ($RotateApiKey) {
            Write-LMStep 'Rotating API key'
            Write-LMWarn 'Rotating the API key will:'
            Write-LMWarn '  - Invalidate all existing client connections'
            Write-LMWarn '  - Require reconfiguration of all clients with the new key'
            $confirm = Read-Host 'Rotate API key? [y/N]'
            if ($confirm -notmatch '^[Yy]$') {
                Write-LMInfo 'API key rotation cancelled.'
            } else {
                if (-not $ServiceAccount) {
                    $wmiSvc = $null
                    try { $wmiSvc = Get-CimInstance Win32_Service -Filter "Name='LegacyMCP'" -ErrorAction SilentlyContinue } catch {}
                    if ($wmiSvc -and $wmiSvc.StartName) { $ServiceAccount = $wmiSvc.StartName }
                }
                if (-not $ServiceAccount) {
                    Write-Error 'Setup: cannot determine service account for API key rotation. Pass -ServiceAccount explicitly.'
                    exit 1
                }
                $newApiKey = New-LMApiKey
                Protect-LMApiKey -ApiKey $newApiKey -ServiceAccount $ServiceAccount -RegistryRoot $REG_ROOT
                Write-Host ''
                Write-LMOK 'New API key (copy this -- it will not be shown again):'
                Write-Host "  $newApiKey" -ForegroundColor Cyan
                Write-Host ''
                Write-LMWarn 'Update all clients with the new API key:'
                Write-LMInfo "  .\Setup-LegacyMCP.ps1 -Profile $Profile -Role Client -Mode Install ..."
                $newApiKey = $null
                $restartRequired = $true
            }
        }

        if ($RotateCert) {
            Write-LMStep 'Rotating TLS certificate'
            Write-LMWarn 'Rotating the TLS certificate will:'
            Write-LMWarn '  - Generate a new self-signed certificate'
            Write-LMWarn '  - Require all clients to import the new CA certificate'
            Write-LMWarn '  - Restart the service automatically'
            $confirm = Read-Host 'Rotate certificate? [y/N]'
            if ($confirm -notmatch '^[Yy]$') {
                Write-LMInfo 'Certificate rotation cancelled.'
            } else {
                if (-not $ServiceAccount) {
                    $wmiSvc = $null
                    try { $wmiSvc = Get-CimInstance Win32_Service -Filter "Name='LegacyMCP'" -ErrorAction SilentlyContinue } catch {}
                    if ($wmiSvc -and $wmiSvc.StartName) { $ServiceAccount = $wmiSvc.StartName }
                }
                if (-not $ServiceAccount) {
                    Write-Error 'Setup: cannot determine service account for certificate rotation. Pass -ServiceAccount explicitly.'
                    exit 1
                }
                $fqdn       = [System.Net.Dns]::GetHostEntry('').HostName
                $certResult = New-LMSelfSignedCert -VenvPython $venvPython -CertDir $CertDir -Hostname $fqdn
                if ($certResult.KeyPassword) {
                    try {
                        $keyBlob = Protect-LMKeyPasswordBlob `
                            -PlainText $certResult.KeyPassword `
                            -ServiceAccount $ServiceAccount
                        Set-LMRegistry -Key $REG_ROOT -Name 'KeyPasswordBlob' -Value $keyBlob
                        Write-LMOK 'TLS key password encrypted and KeyPasswordBlob updated.'
                    } catch {
                        Write-Error "Setup: Failed to encrypt TLS key password: $_"
                        exit 1
                    } finally {
                        $certResult.KeyPassword = $null
                        [System.GC]::Collect()
                    }
                }
                Update-LMYamlSslFields `
                    -YamlPath $ConfigPath `
                    -SslCertFile $certResult.CertFile `
                    -SslKeyFile $certResult.KeyFile `
                    -VenvPython $venvPython
                Write-LMOK 'ssl_certfile and ssl_keyfile updated in config.yaml.'
                Write-LMInfo 'Restarting service...'
                Restart-Service -Name $SERVICE_NAME -Force
                Write-LMOK "Service restarted with new certificate."
                Write-LMWarn 'Distribute the new CA certificate to all clients:'
                Write-LMInfo "  $($certResult.CertFile)"
                Write-LMWarn 'On each client, run:'
                Write-LMInfo "  .\Setup-LegacyMCP.ps1 -Profile $Profile -Role Client -Mode Install ..."
                Write-LMInfo "    -CaCertPath <path-to-new-server.crt>"
                $restartRequired = $false
            }
        }

        Write-LMStep 'Configure complete'
        Write-LMOK  "Profile $Profile Server configuration updated."
        if ($restartRequired) {
            Write-LMWarn 'Restart the service for changes to take effect:'
            Write-LMInfo "  Restart-Service -Name $SERVICE_NAME"
        }

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

        $ps1Source = Join-Path $ScriptDir 'mcp-remote-live.ps1'
        if (-not (Test-Path $ps1Source)) {
            $ps1Source = Join-Path $RepoRoot 'client\mcp-remote-live.ps1'
        }
        if (-not (Test-Path $ps1Source)) {
            $ps1Source = Join-Path $ScriptDir 'client\mcp-remote-live.ps1'
        }
        if (-not (Test-Path $ps1Source)) {
            throw "mcp-remote-live.ps1 not found. Checked: $(Join-Path $ScriptDir 'mcp-remote-live.ps1'), $(Join-Path $RepoRoot 'client\mcp-remote-live.ps1'), $(Join-Path $ScriptDir 'client\mcp-remote-live.ps1')"
        }
        $Ps1Path = Join-Path $ClientPath 'mcp-remote-live.ps1'

        foreach ($dir in @($ClientPath, $ClientCertDir)) {
            if (-not (Test-Path $dir)) {
                try {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                } catch {
                    Write-Error "Setup: Failed to create directory '$dir': $_"
                    exit 1
                }
                Write-LMOK "Created: $dir"
            }
        }

        if ($ServerUrl -notmatch '^https://') {
            throw "ServerUrl must start with https://. Got: $ServerUrl"
        }
        if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
            Write-LMWarn 'npx not found in PATH. Install Node.js (https://nodejs.org) and ensure npx is in PATH.'
            Write-LMWarn 'Continuing -- npx must be available before Claude Desktop can use this MCP server.'
        }

        Write-LMStep 'Step 1 -- CA certificate'
        if (-not (Test-Path $CaCertPath)) { throw "CA certificate not found: $CaCertPath" }
        $localCertPath = Join-Path $ClientCertDir (Split-Path $CaCertPath -Leaf)
        Copy-Item -Path $CaCertPath -Destination $localCertPath -Force
        Write-LMOK "CA certificate copied to: $localCertPath"
        Write-LMInfo 'NODE_EXTRA_CA_CERTS will be set in the BAT entry point.'

        Write-LMStep 'Step 2 -- API key'
        $keyPath = Join-Path $ClientPath '.legacymcp-key'
        if (-not $ApiKey) {
            $apiKeySecure = Read-Host "Enter the API key for $ServerUrl" -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($apiKeySecure)
            try {
                $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            } finally {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        } else {
            Write-LMInfo "Using API key provided via -ApiKey parameter."
        }
        if (-not $ApiKey) { throw 'API key cannot be empty.' }
        Protect-LMClientApiKey -ApiKey $ApiKey -OutputPath $keyPath
        $ApiKey = $null

        Write-LMStep 'Step 3 -- BAT entry point'
        Copy-Item -Path $ps1Source -Destination $Ps1Path -Force
        Write-LMOK "mcp-remote-live.ps1 copied to: $Ps1Path"
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
