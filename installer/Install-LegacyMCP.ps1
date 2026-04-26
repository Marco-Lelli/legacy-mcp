#Requires -Version 5.1
<#
.SYNOPSIS
    Install LegacyMCP for Profile A (local stdio) or Profile B (LAN service).

.DESCRIPTION
    Runs pre-flight checks, creates the Python virtual environment, installs
    dependencies, writes the Windows registry configuration, registers the
    EventLog source, and (for Profile B) installs the NSSM Windows service.
    Finishes with a self-check via Config-LegacyMCP.ps1 -Validate.

.PARAMETER DeployProfile
    A  -- local stdio mode (consultant's machine, no service)
    B  -- shared LAN mode (Windows service via NSSM, requires Administrator)

.EXAMPLE
    .\Install-LegacyMCP.ps1 -DeployProfile A
    .\Install-LegacyMCP.ps1 -DeployProfile B -ServiceAccount CONTOSO\legacymcp$
#>

param(
    [ValidateSet('A','B')]
    [string]$DeployProfile = 'A',
    [string]$ServiceAccount = '',
    [switch]$Force,
    [string]$ApiKey = '',
    [string]$CertFile = '',
    [string]$CertKeyFile = '',
    [string]$CertThumbprint = '',
    [ValidateSet('Install', 'ReplaceCert')]
    [string]$Action = 'Install',
    [string]$SnapshotPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve installation root (parent of installer\)
# ---------------------------------------------------------------------------
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$InstallPath = Split-Path -Parent $ScriptDir   # repo / install root
$NssmExe     = Join-Path $ScriptDir 'tools\nssm.exe'

# Default paths derived from install root
$ConfigPath  = Join-Path $InstallPath 'config\config.yaml'
$LogPath             = Join-Path $InstallPath 'logs'
$SnapshotPathEffective = if ($SnapshotPath) { $SnapshotPath } else { Join-Path $InstallPath 'snapshots' }
$VenvPython  = Join-Path $InstallPath '.venv\Scripts\python.exe'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-OK   { param([string]$Msg); Write-Host "  [OK]   $Msg" -ForegroundColor Green  }
function Write-Warn { param([string]$Msg); Write-Host "  [WARN] $Msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg); Write-Host "  [FAIL] $Msg" -ForegroundColor Red    }
function Write-Info { param([string]$Msg); Write-Host "  [INFO] $Msg" -ForegroundColor Cyan   }
function Write-Step { param([string]$Msg); Write-Host "`n==> $Msg" -ForegroundColor White     }

# ---------------------------------------------------------------------------
# Helper: partial YAML merge -- update ssl_certfile / ssl_keyfile only
# ---------------------------------------------------------------------------
function Update-YamlSslFields {
    param(
        [string]$YamlPath,
        [string]$SslCertFile,
        [string]$SslKeyFile
    )
    $certLine = "  ssl_certfile: $SslCertFile"
    $keyLine  = "  ssl_keyfile:  $SslKeyFile"
    $content  = Get-Content $YamlPath -Raw

    # Replace existing line (commented or uncommented); otherwise inject under server:
    if ($content -match '(?m)^\s*#?\s*ssl_certfile\s*:') {
        $content = $content -replace '(?m)^\s*#?\s*ssl_certfile\s*:.*', $certLine
    } else {
        # Append as first new line inside the server: block
        $content = $content -replace '(?m)(^server\s*:.*(?:\r?\n(?:[ \t][^\r\n]*))*)', "`$1`n$certLine"
    }
    if ($content -match '(?m)^\s*#?\s*ssl_keyfile\s*:') {
        $content = $content -replace '(?m)^\s*#?\s*ssl_keyfile\s*:.*', $keyLine
    } else {
        $content = $content -replace '(?m)(^\s*ssl_certfile\s*:.*)', "`$1`n$keyLine"
    }
    [System.IO.File]::WriteAllText($YamlPath, $content, [System.Text.Encoding]::UTF8)
}

# ---------------------------------------------------------------------------
# Helper: write snapshot_path into config.yaml server: block
# ---------------------------------------------------------------------------
function Update-YamlSnapshotPath {
    param(
        [string]$YamlPath,
        [string]$SnapshotPathValue
    )
    $allLines = Get-Content $YamlPath -Encoding UTF8
    $inServerBlock = $false
    $snapshotIdx   = -1
    $serverIdx     = -1
    for ($i = 0; $i -lt $allLines.Count; $i++) {
        $line = $allLines[$i]
        if ($line.TrimEnd() -eq 'server:') {
            $inServerBlock = $true
            $serverIdx = $i
        } elseif ($inServerBlock -and $line.Length -gt 0 -and $line[0] -ne ' ' -and $line[0] -ne '#' -and $line[0] -ne "`t") {
            $inServerBlock = $false
        }
        if ($inServerBlock -and $line.TrimStart().StartsWith('snapshot_path')) {
            $snapshotIdx = $i
        }
    }
    $newLine = "  snapshot_path: $SnapshotPathValue"
    $result  = [System.Collections.Generic.List[string]]::new()
    if ($snapshotIdx -ge 0) {
        for ($i = 0; $i -lt $allLines.Count; $i++) {
            if ($i -eq $snapshotIdx) { $result.Add($newLine) } else { $result.Add($allLines[$i]) }
        }
    } elseif ($serverIdx -ge 0) {
        for ($i = 0; $i -lt $allLines.Count; $i++) {
            $result.Add($allLines[$i])
            if ($i -eq $serverIdx) { $result.Add($newLine) }
        }
    } else {
        foreach ($l in $allLines) { $result.Add($l) }
        $result.Add('server:')
        $result.Add($newLine)
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllLines($YamlPath, $result, $utf8NoBom)
}

# ---------------------------------------------------------------------------
# -Action ReplaceCert: partial config.yaml SSL update + service restart
# ---------------------------------------------------------------------------
if ($Action -eq 'ReplaceCert') {
    Write-Step 'ReplaceCert -- updating TLS certificate in config.yaml'

    if (-not $CertFile -or -not $CertKeyFile) {
        Write-Fail '-CertFile and -CertKeyFile are required for -Action ReplaceCert.'
        exit 1
    }
    if (-not (Test-Path $CertFile)) {
        Write-Fail "Certificate file not found: $CertFile"
        exit 1
    }
    if (-not (Test-Path $CertKeyFile)) {
        Write-Fail "Key file not found: $CertKeyFile"
        exit 1
    }
    if (-not (Test-Path $ConfigPath)) {
        Write-Fail "config.yaml not found at: $ConfigPath"
        exit 1
    }

    Update-YamlSslFields -YamlPath $ConfigPath -SslCertFile $CertFile -SslKeyFile $CertKeyFile
    Write-OK 'ssl_certfile and ssl_keyfile updated in config.yaml.'

    $svc = Get-Service -Name 'LegacyMCP' -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Info 'Restarting LegacyMCP service...'
        Restart-Service -Name 'LegacyMCP' -Force
        Write-OK 'LegacyMCP service restarted.'
    } else {
        Write-Warn 'LegacyMCP service not found -- skipping restart.'
    }

    # Retrieve and display stored API key so the caller can update their MCP client config
    $displayKey = '<read-from-registry>'
    try {
        Import-Module SecretManagement.DpapiNG -ErrorAction Stop
        $encStr = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\LegacyMCP' -Name 'ApiKey' -ErrorAction Stop
        $displayKey = ConvertFrom-DpapiNGSecret -InputObject $encStr
    } catch {
        Write-Warn "Could not read ApiKey from registry: $_"
    }

    $serverName = "$env:COMPUTERNAME.$env:USERDNSDOMAIN"

    Write-Host ''
    Write-Host '==========================================' -ForegroundColor Yellow
    Write-Host '  API KEY -- share securely with consultants' -ForegroundColor Yellow
    Write-Host '  Run Setup-LegacyMCPClient.ps1 on each consultant PC.' -ForegroundColor Yellow
    Write-Host '==========================================' -ForegroundColor Yellow
    Write-Host "  $displayKey" -ForegroundColor Yellow
    Write-Host '==========================================' -ForegroundColor Yellow
    Write-Host ''
    Write-Info "Setup-LegacyMCPClient.ps1 parameters:"
    Write-Host "  -ApiKey `"$displayKey`"" -ForegroundColor White
    Write-Host "  -ServerUrl `"https://$serverName`:8000/mcp`"" -ForegroundColor White
    Write-Host "  -CaCertPath `"<path to $CertFile on consultant PC>`"" -ForegroundColor White
    Write-Host ''
    Write-Host '==========================================' -ForegroundColor White
    Write-Host '  claude_desktop_config.json template' -ForegroundColor White
    Write-Host '  (run Setup-LegacyMCPClient.ps1 -- do not paste API key in the JSON)' -ForegroundColor White
    Write-Host '==========================================' -ForegroundColor White
    Write-Host ''
    Write-Host '{'
    Write-Host '  "mcpServers": {'
    Write-Host '    "legacymcp-live": {'
    Write-Host '      "command": "npx",'
    Write-Host '      "args": ['
    Write-Host '        "mcp-remote",'
    Write-Host "        `"https://$serverName`:8000/mcp`","
    Write-Host '        "--header",'
    Write-Host '        "Authorization:${AUTH_HEADER}"'
    Write-Host '      ],'
    Write-Host '      "env": {'
    Write-Host '        "AUTH_HEADER": "Bearer <run Setup-LegacyMCPClient.ps1>",'
    Write-Host '        "NODE_EXTRA_CA_CERTS": "<run Setup-LegacyMCPClient.ps1>"'
    Write-Host '      }'
    Write-Host '    }'
    Write-Host '  }'
    Write-Host '}'
    Write-Host ''
    Write-Host '==========================================' -ForegroundColor White
    Write-Host ''
    exit 0
}

# ---------------------------------------------------------------------------
# Phase 1 -- Pre-flight checks
# ---------------------------------------------------------------------------
Write-Step 'Phase 1 -- Pre-flight checks'

$preflightFail = $false

# Python 3.10+
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd) {
    Write-Fail 'Python not found in PATH. Install Python 3.10 or later.'
    $preflightFail = $true
} else {
    $pyVerRaw = & python --version 2>&1
    if ($pyVerRaw -match 'Python (\d+)\.(\d+)') {
        $pyMajor = [int]$Matches[1]
        $pyMinor = [int]$Matches[2]
        if ($pyMajor -lt 3 -or ($pyMajor -eq 3 -and $pyMinor -lt 10)) {
            Write-Fail "Python $pyMajor.$pyMinor found -- version 3.10 or later required."
            $preflightFail = $true
        } else {
            Write-OK "Python $pyMajor.$pyMinor found."
        }
    } else {
        Write-Fail "Could not determine Python version from: $pyVerRaw"
        $preflightFail = $true
    }
}

# pip
$pipCmd = Get-Command pip -ErrorAction SilentlyContinue
if (-not $pipCmd) {
    Write-Fail 'pip not found. Ensure pip is available in PATH.'
    $preflightFail = $true
} else {
    Write-OK 'pip available.'
}

# PowerShell 5.1 (for collector)
$psVer = $PSVersionTable.PSVersion
if ($psVer.Major -lt 5 -or ($psVer.Major -eq 5 -and $psVer.Minor -lt 1)) {
    Write-Warn "PowerShell $($psVer.Major).$($psVer.Minor) found -- 5.1 or later recommended for the collector."
} else {
    Write-OK "PowerShell $($psVer.Major).$($psVer.Minor) found."
}

# Git (optional)
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Warn 'Git not found -- not required for runtime.'
} else {
    Write-OK 'Git available.'
}

# Administrator check for Profile B
if ($DeployProfile -eq 'B') {
    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Fail 'Profile B installation requires Administrator privileges. Re-run as Administrator.'
        $preflightFail = $true
    } else {
        Write-OK 'Running as Administrator.'
    }
}

# ServiceAccount required for Profile B (not needed for ReplaceCert -- exits before Phase 5)
if ($DeployProfile -eq 'B' -and -not $ServiceAccount -and $Action -ne 'ReplaceCert') {
    Write-Fail '-ServiceAccount is required for Profile B. LocalSystem has no Kerberos identity -- Live Mode would not work.'
    Write-Fail 'Example (gMSA):    .\Install-LegacyMCP.ps1 -Profile B -ServiceAccount CONTOSO\legacymcp$'
    Write-Fail 'Example (user):    .\Install-LegacyMCP.ps1 -Profile B -ServiceAccount CONTOSO\svc-legacymcp'
    $preflightFail = $true
}

# NSSM available for Profile B
if ($DeployProfile -eq 'B') {
    if (-not (Test-Path $NssmExe)) {
        Write-Fail "nssm.exe not found at: $NssmExe"
        Write-Fail 'Download nssm-2.24.zip from https://nssm.cc and place nssm.exe in installer\tools\'
        $preflightFail = $true
    } else {
        Write-OK "nssm.exe found: $NssmExe"
    }
}

# RSAT modules (Profile B -- required for Live Mode: ActiveDirectory and DnsServer PS modules)
if ($DeployProfile -eq 'B') {
    $isWindowsServer = $false
    try {
        $isWindowsServer = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).ProductType -ne 1
    } catch {
        Write-Warn "Could not detect OS type -- assuming Windows Server for RSAT check."
        $isWindowsServer = $true
    }

    function Test-AndInstall-RsatFeature {
        param(
            [string]$FeatureName,
            [string]$CapabilityPattern,
            [string]$CapabilityFull,
            [string]$DisplayName
        )
        if ($script:isWindowsServer) {
            $feature = Get-WindowsFeature $FeatureName -ErrorAction SilentlyContinue
            if ($feature -and $feature.InstallState -eq 'Installed') {
                Write-OK "$DisplayName already installed."
                return
            }
            Write-Info "Installing $DisplayName ..."
            try {
                Add-WindowsFeature $FeatureName -ErrorAction Stop | Out-Null
                Write-OK "$DisplayName installed successfully."
            } catch {
                Write-Fail "$DisplayName installation failed: $_"
                Write-Fail "Install manually:  Add-WindowsFeature $FeatureName"
                $script:preflightFail = $true
            }
        } else {
            $cap = Get-WindowsCapability -Online -Name $CapabilityPattern -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($cap -and $cap.State -eq 'Installed') {
                Write-OK "$DisplayName already installed."
                return
            }
            Write-Info "Installing $DisplayName ..."
            try {
                Add-WindowsCapability -Online -Name $CapabilityFull -ErrorAction Stop | Out-Null
                Write-OK "$DisplayName installed successfully."
            } catch {
                Write-Fail "$DisplayName installation failed: $_"
                Write-Fail "Install manually:  Add-WindowsCapability -Online -Name `"$CapabilityFull`""
                $script:preflightFail = $true
            }
        }
    }

    Test-AndInstall-RsatFeature `
        -FeatureName       'RSAT-AD-PowerShell' `
        -CapabilityPattern 'Rsat.ActiveDirectory*' `
        -CapabilityFull    'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0' `
        -DisplayName       'RSAT-AD-PowerShell'

    Test-AndInstall-RsatFeature `
        -FeatureName       'RSAT-DNS-Server' `
        -CapabilityPattern 'Rsat.Dns*' `
        -CapabilityFull    'Rsat.Dns.Tools~~~~0.0.1.0' `
        -DisplayName       'RSAT-DNS-Server'
}

if ($preflightFail) {
    Write-Host ''
    Write-Host 'Installation aborted -- resolve the [FAIL] items above and re-run.' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Phase 2 -- Installation
# ---------------------------------------------------------------------------
Write-Step 'Phase 2 -- Installation'

# Create virtual environment
$VenvDir = Join-Path $InstallPath '.venv'
if ($Force -and (Test-Path $VenvDir)) {
    Write-Info "Removing existing virtual environment (-Force): $VenvDir"
    Remove-Item $VenvDir -Recurse -Force
    Write-OK 'Existing virtual environment removed.'
}
if (-not (Test-Path $VenvDir)) {
    Write-Info "Creating virtual environment in: $VenvDir"
    & python -m venv $VenvDir
    Write-OK 'Virtual environment created.'
} else {
    Write-Info 'Virtual environment already exists -- skipping creation.'
}

# Always install/update the package (runs whether venv was just created or pre-existing)
Write-Info 'Installing LegacyMCP package (pip install -e .) ...'
& "$VenvDir\Scripts\python.exe" -m pip install -e $InstallPath --quiet
Write-OK 'Package installed.'

# Copy config template if config.yaml does not exist
$ConfigExampleKey = if ($DeployProfile -eq 'B') { 'config.example-B.yaml' } else { 'config.example-A.yaml' }
$ConfigExample    = Join-Path $InstallPath "config\$ConfigExampleKey"

if (-not (Test-Path $ConfigPath)) {
    if (Test-Path $ConfigExample) {
        Copy-Item -Path $ConfigExample -Destination $ConfigPath
        Write-OK "config.yaml created from $ConfigExampleKey."
    } else {
        Write-Warn "Template $ConfigExampleKey not found -- config.yaml not created. Create it manually."
    }
} else {
    Write-OK "config.yaml already exists -- not overwritten."
}

# Create log directory
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    Write-OK "Log directory created: $LogPath"
} else {
    Write-OK "Log directory already exists: $LogPath"
}

# Create snapshot directory
if (-not (Test-Path $SnapshotPathEffective)) {
    New-Item -ItemType Directory -Path $SnapshotPathEffective -Force | Out-Null
    Write-OK "Snapshot directory created: $SnapshotPathEffective"
} else {
    Write-OK "Snapshot directory already exists: $SnapshotPathEffective"
}

# ---------------------------------------------------------------------------
# Phase 3 -- Registry
# ---------------------------------------------------------------------------
Write-Step 'Phase 3 -- Windows Registry'

$RegRoot = 'HKLM:\SOFTWARE\LegacyMCP'
if (-not (Test-Path $RegRoot)) {
    New-Item -Path $RegRoot -Force | Out-Null
}

$transport = if ($DeployProfile -eq 'B') { 'streamable-http' } else { 'stdio' }

Set-ItemProperty -Path $RegRoot -Name 'InstallPath' -Value $InstallPath -Type String
Set-ItemProperty -Path $RegRoot -Name 'ConfigPath'  -Value $ConfigPath  -Type String
Set-ItemProperty -Path $RegRoot -Name 'LogPath'     -Value $LogPath     -Type String
Set-ItemProperty -Path $RegRoot -Name 'Profile'     -Value $DeployProfile     -Type String
Set-ItemProperty -Path $RegRoot -Name 'Transport'   -Value $transport   -Type String
Set-ItemProperty -Path $RegRoot -Name 'Port'        -Value 8000         -Type DWord

# Version from pyproject.toml (best effort)
$PyprojectPath = Join-Path $InstallPath 'pyproject.toml'
if (Test-Path $PyprojectPath) {
    $pyprojectContent = Get-Content $PyprojectPath -Raw
    if ($pyprojectContent -match 'version\s*=\s*"([^"]+)"') {
        Set-ItemProperty -Path $RegRoot -Name 'Version' -Value $Matches[1] -Type String
        Write-OK "Version set to $($Matches[1])."
    }
}

# Service subkey
$RegService = 'HKLM:\SOFTWARE\LegacyMCP\Service'
if (-not (Test-Path $RegService)) {
    New-Item -Path $RegService -Force | Out-Null
}
$autoStart = if ($DeployProfile -eq 'B') { 1 } else { 0 }
Set-ItemProperty -Path $RegService -Name 'AutoStart' -Value $autoStart -Type DWord

Write-OK 'Registry written.'

# ---------------------------------------------------------------------------
# Phase 3.5 -- API Key + TLS Certificate (Profile B only)
# ---------------------------------------------------------------------------
if ($DeployProfile -eq 'B') {
    Write-Step 'Phase 3.5 -- API Key and TLS Certificate'

    # --- API Key ---
    if (-not $ApiKey) {
        $ApiKey = (New-Guid).ToString()
        Write-Info "API key generated (copy from the output block below)."
    } else {
        Write-Info 'Using provided API key.'
    }

    try {
        Import-Module SecretManagement.DpapiNG -ErrorAction Stop
        $svcSid = (New-Object System.Security.Principal.NTAccount($ServiceAccount)).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
        $encryptedKey = ConvertTo-DpapiNGSecret -InputObject $ApiKey -Sid $svcSid
        Set-ItemProperty -Path $RegRoot -Name 'ApiKey' -Value $encryptedKey -Type String
        Write-OK 'API key stored encrypted (DPAPI-NG, SID-scoped) in HKLM:\SOFTWARE\LegacyMCP\ApiKey.'
    } catch {
        Write-Fail "Failed to encrypt API key with DPAPI-NG: $_"
        exit 1
    }

    # --- TLS Certificate ---
    $CertDir = Join-Path $InstallPath 'certs'
    if (-not (Test-Path $CertDir)) {
        New-Item -ItemType Directory -Path $CertDir -Force | Out-Null
    }

    $resolvedCertFile = $CertFile
    $resolvedKeyFile  = $CertKeyFile

    if ($CertFile -and $CertKeyFile) {
        # Existing PEM files provided
        if (-not (Test-Path $CertFile)) {
            Write-Fail "Certificate file not found: $CertFile"
            exit 1
        }
        if (-not (Test-Path $CertKeyFile)) {
            Write-Fail "Key file not found: $CertKeyFile"
            exit 1
        }
        Write-OK "Using existing certificate: $CertFile"

    } elseif ($CertThumbprint) {
        # Export certificate from Windows certificate store by thumbprint
        $resolvedCertFile = Join-Path $CertDir 'server.crt'
        $resolvedKeyFile  = Join-Path $CertDir 'server.key'
        $tmpPfxPath = Join-Path $env:TEMP "legacymcp_$([System.Guid]::NewGuid().ToString('N')).pfx"
        $tmpPfxPass = [System.Guid]::NewGuid().ToString('N')

        $storeCert = Get-ChildItem 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
                     Where-Object { $_.Thumbprint -eq $CertThumbprint.ToUpper() }
        if (-not $storeCert) {
            $storeCert = Get-ChildItem 'Cert:\LocalMachine\WebHosting' -ErrorAction SilentlyContinue |
                         Where-Object { $_.Thumbprint -eq $CertThumbprint.ToUpper() }
        }
        if (-not $storeCert) {
            Write-Fail "Certificate with thumbprint '$CertThumbprint' not found in LocalMachine stores."
            exit 1
        }

        $secPass = $tmpPfxPass | ConvertTo-SecureString -AsPlainText -Force
        Export-PfxCertificate -Cert $storeCert -FilePath $tmpPfxPath -Password $secPass | Out-Null
        Write-Info 'Certificate exported to PFX. Converting to PEM...'

        $venvPy = Join-Path $InstallPath '.venv\Scripts\python.exe'
        $convertPy = @"
from cryptography.hazmat.primitives.serialization import pkcs12, Encoding, PrivateFormat, NoEncryption
with open(r'$tmpPfxPath', 'rb') as f: data = f.read()
key, cert, chain = pkcs12.load_key_and_certificates(data, b'$tmpPfxPass')
with open(r'$resolvedCertFile', 'wb') as f:
    f.write(cert.public_bytes(Encoding.PEM))
    for c in (chain or []):
        f.write(c.public_bytes(Encoding.PEM))
with open(r'$resolvedKeyFile', 'wb') as f:
    f.write(key.private_bytes(Encoding.PEM, PrivateFormat.TraditionalOpenSSL, NoEncryption()))
"@
        & $venvPy -c $convertPy
        Remove-Item $tmpPfxPath -Force -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0) {
            Write-Fail 'PFX to PEM conversion failed.'
            exit 1
        }
        Write-OK "Certificate exported to PEM: $resolvedCertFile"

    } else {
        # No certificate provided -- generate self-signed
        $resolvedCertFile = Join-Path $CertDir 'server.crt'
        $resolvedKeyFile  = Join-Path $CertDir 'server.key'
        Write-Info 'No certificate provided -- generating self-signed certificate...'

        $venvPy = Join-Path $InstallPath '.venv\Scripts\python.exe'
        $genPy = @"
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
import datetime, socket
hostname = socket.getfqdn()
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, hostname)])
cert = (
    x509.CertificateBuilder()
    .subject_name(name)
    .issuer_name(name)
    .public_key(key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(datetime.datetime.utcnow())
    .not_valid_after(datetime.datetime.utcnow() + datetime.timedelta(days=730))
    .add_extension(x509.SubjectAlternativeName([
        x509.DNSName(hostname),
        x509.DNSName(socket.gethostname()),
        x509.DNSName('localhost'),
    ]), critical=False)
    .sign(key, hashes.SHA256())
)
with open(r'$resolvedCertFile', 'wb') as f:
    f.write(cert.public_bytes(serialization.Encoding.PEM))
with open(r'$resolvedKeyFile', 'wb') as f:
    f.write(key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption()
    ))
print('OK')
"@
        & $venvPy -c $genPy | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Fail 'Failed to generate self-signed certificate.'
            exit 1
        }
        Write-OK "Self-signed certificate generated: $resolvedCertFile"
        Write-Warn "Clients must trust this CA. Copy $resolvedCertFile to the consultant PC and set NODE_EXTRA_CA_CERTS."
    }

    # Write ssl_certfile / ssl_keyfile into config.yaml (partial merge -- only these two keys)
    if (Test-Path $ConfigPath) {
        Update-YamlSslFields -YamlPath $ConfigPath -SslCertFile $resolvedCertFile -SslKeyFile $resolvedKeyFile
        Write-OK 'ssl_certfile and ssl_keyfile written to config.yaml.'
    } else {
        Write-Warn "config.yaml not found at $ConfigPath -- set ssl_certfile and ssl_keyfile manually."
    }

    # Write snapshot_path into config.yaml
    if (Test-Path $ConfigPath) {
        try {
            Update-YamlSnapshotPath -YamlPath $ConfigPath -SnapshotPathValue $SnapshotPathEffective
            Write-OK "snapshot_path written to config.yaml: $SnapshotPathEffective"
        } catch {
            Write-Fail "Cannot update snapshot_path in config.yaml: $_"
            exit 1
        }
    } else {
        Write-Warn "config.yaml not found -- set snapshot_path manually under server: in config.yaml."
    }

    # Grant service account write access on snapshot directory (required for create_snapshot)
    Write-Info "Granting write access to '$ServiceAccount' on snapshot directory..."
    try {
        $icaclsOut = & icacls $SnapshotPathEffective /grant "${ServiceAccount}:(M)" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Cannot grant write access on '$SnapshotPathEffective' for '$ServiceAccount': $icaclsOut"
            exit 1
        }
        Write-OK "Write access granted to '$ServiceAccount' on: $SnapshotPathEffective"
    } catch {
        Write-Fail "Error setting permissions on snapshot directory '$SnapshotPathEffective': $_"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Phase 4 -- EventLog
# ---------------------------------------------------------------------------
Write-Step 'Phase 4 -- EventLog registration'

$RegisterEventLog = Join-Path $InstallPath 'scripts\Register-EventLog.ps1'
if (Test-Path $RegisterEventLog) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RegisterEventLog
} else {
    Write-Warn "Register-EventLog.ps1 not found at: $RegisterEventLog -- skipping."
}

# ---------------------------------------------------------------------------
# Phase 5 -- NSSM service (Profile B only)
# ---------------------------------------------------------------------------
if ($DeployProfile -eq 'B') {
    Write-Step 'Phase 5 -- Windows Service (NSSM)'

    $svcPython = $VenvPython

    # Remove existing service if present (idempotent reinstall)
    $existingSvc = Get-Service -Name 'LegacyMCP' -ErrorAction SilentlyContinue
    if ($existingSvc) {
        Write-Info 'Removing existing LegacyMCP service for clean reinstall...'
        Stop-Service -Name 'LegacyMCP' -Force -ErrorAction SilentlyContinue
        & $NssmExe remove LegacyMCP confirm
    }

    $PythonExe = Join-Path $InstallPath '.venv\Scripts\python.exe'
    & $NssmExe install  LegacyMCP $PythonExe
    $NssmArgs  = "-m legacy_mcp.server --config `"$ConfigPath`" --transport streamable-http"
    & $NssmExe set      LegacyMCP AppParameters  $NssmArgs
    & $NssmExe set      LegacyMCP AppDirectory   $InstallPath
    & $NssmExe set      LegacyMCP Description   'Legacy MCP Server for Active Directory (Profile B)'
    & $NssmExe set      LegacyMCP Start         SERVICE_AUTO_START
    & $NssmExe set      LegacyMCP AppStdout     (Join-Path $LogPath 'legacymcp.log')
    & $NssmExe set      LegacyMCP AppStderr     (Join-Path $LogPath 'legacymcp-error.log')

    Write-OK 'LegacyMCP service installed via NSSM.'

    # Configure service account
    if ($ServiceAccount.EndsWith('$')) {
        # gMSA -- empty password; AD grants SeServiceLogonRight automatically
        & $NssmExe set LegacyMCP ObjectName $ServiceAccount ""
        Write-OK "Service account set to gMSA: $ServiceAccount"
    } else {
        try {
            $svcSecure   = Read-Host "Password for $ServiceAccount" -AsSecureString
            $svcPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($svcSecure))
            & $NssmExe set LegacyMCP ObjectName $ServiceAccount $svcPassword
        } catch {
            Write-Fail "Failed to set service account credentials: $_"
            exit 1
        } finally {
            if ($svcSecure)   { $svcSecure.Dispose() }
            if ($svcPassword) { $svcPassword = $null }
        }
        Write-OK "Service account set to: $ServiceAccount"

        # SeServiceLogonRight check -- non-gMSA accounts must have this right
        # to start a Windows service. gMSA receive it automatically from AD.
        Write-Info "Checking 'Log on as a service' right for: $ServiceAccount"

        $secpolCfg = Join-Path $env:TEMP 'legacymcp_secpol.cfg'
        $seceditDb  = Join-Path $env:TEMP 'legacymcp_secedit.sdb'

        try {
            # Resolve account to SID
            $ntAcct = New-Object System.Security.Principal.NTAccount($ServiceAccount)
            $sid    = $ntAcct.Translate([System.Security.Principal.SecurityIdentifier]).Value

            # Export current local security policy
            & secedit /export /cfg $secpolCfg /quiet | Out-Null
            $cfgContent = Get-Content $secpolCfg -Raw -Encoding Unicode

            if ($cfgContent -match "SeServiceLogonRight\s*=.*\*$sid") {
                Write-OK "Account has 'Log on as a service' right."
            } elseif ($isAdmin) {
                # Add the SID to SeServiceLogonRight
                $lines   = $cfgContent -split '\r?\n'
                $patched = $false
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match '^SeServiceLogonRight\s*=') {
                        $lines[$i] = $lines[$i].TrimEnd() + ",*$sid"
                        $patched = $true
                        break
                    }
                }
                if (-not $patched) {
                    # No existing entry -- insert under [Privilege Rights]
                    for ($i = 0; $i -lt $lines.Count; $i++) {
                        if ($lines[$i] -match '^\[Privilege Rights\]') {
                            $before = $lines[0..$i]
                            $after  = if ($i + 1 -lt $lines.Count) { $lines[($i+1)..($lines.Count-1)] } else { @() }
                            $lines  = $before + "SeServiceLogonRight = *$sid" + $after
                            break
                        }
                    }
                }
                [System.IO.File]::WriteAllText(
                    $secpolCfg,
                    ($lines -join "`r`n"),
                    [System.Text.Encoding]::Unicode
                )
                & secedit /configure /db $seceditDb /cfg $secpolCfg /areas USER_RIGHTS /quiet | Out-Null
                Write-Warn "Granted 'Log on as a service' to $ServiceAccount -- verify in secpol.msc before production deployment"
            } else {
                Write-Fail "ServiceAccount '$ServiceAccount' does not have 'Log on as a service' right (SeServiceLogonRight). Grant it manually in: secpol.msc -> Local Policies -> User Rights Assignment, or re-run this installer as Administrator for automatic grant."
                exit 1
            }
        } catch {
            Write-Warn "Could not check SeServiceLogonRight: $_"
        } finally {
            if (Test-Path $secpolCfg) { Remove-Item $secpolCfg -Force -ErrorAction SilentlyContinue }
            if (Test-Path $seceditDb)  { Remove-Item $seceditDb  -Force -ErrorAction SilentlyContinue }
        }
    }

    Write-Info "Start with: Start-Service LegacyMCP"
    Write-Info "Status:     Get-Service LegacyMCP"

    # ---------------------------------------------------------------------------
    # Phase 5.5 -- Windows Firewall
    # ---------------------------------------------------------------------------
    Write-Step 'Phase 5.5 -- Windows Firewall'

    $fwRuleName = 'LegacyMCP MCP Server'
    $existingRule = Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue
    if ($existingRule) {
        Write-OK "Firewall rule '$fwRuleName' already exists -- skipping."
    } else {
        try {
            New-NetFirewallRule `
                -DisplayName $fwRuleName `
                -Direction Inbound `
                -Protocol TCP `
                -LocalPort 8000 `
                -Action Allow `
                -Profile Domain,Private | Out-Null
            Write-OK "Firewall rule created: allow TCP inbound port 8000 (Domain, Private profiles)."
        } catch {
            Write-Warn "Could not create firewall rule: $_"
            Write-Warn "Create it manually: New-NetFirewallRule -DisplayName '$fwRuleName' -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Domain,Private"
        }
    }
}

# ---------------------------------------------------------------------------
# Phase 6 -- Output
# ---------------------------------------------------------------------------
Write-Step 'Phase 6 -- Next steps'

if ($DeployProfile -eq 'A') {
    $escapedPython = $VenvPython -replace '\\', '\\'
    Write-Host ''
    Write-Host '=========================================='
    Write-Host '  Add this block to:'
    Write-Host '  %APPDATA%\Claude\claude_desktop_config.json'
    Write-Host '=========================================='
    Write-Host ''
    Write-Host '{'
    Write-Host '  "mcpServers": {'
    Write-Host '    "legacymcp": {'
    Write-Host "      `"command`": `"$escapedPython`","
    Write-Host '      "args": ["-m", "legacy_mcp.server"]'
    Write-Host '    }'
    Write-Host '  }'
    Write-Host '}'
    Write-Host ''
    Write-Host 'Restart Claude Desktop to activate LegacyMCP.'
    Write-Host '=========================================='
    Write-Host ''
} else {
    Write-Host ''
    Write-Info "Service installed. Start it with:"
    Write-Host "    Start-Service LegacyMCP" -ForegroundColor White
    Write-Info "Verify status:"
    Write-Host "    Get-Service LegacyMCP" -ForegroundColor White
    Write-Info "Check logs:"
    Write-Host "    Get-Content '$LogPath\legacymcp.log' -Tail 50 -Wait" -ForegroundColor White
    Write-Host ''

    $serverName  = "$env:COMPUTERNAME.$env:USERDNSDOMAIN"
    $certDisplay = if ($resolvedCertFile) { $resolvedCertFile } else { 'C:\LegacyMCP\certs\server.crt' }

    Write-Host ''
    Write-Host '==========================================' -ForegroundColor Yellow
    Write-Host '  API KEY -- share securely with consultants' -ForegroundColor Yellow
    Write-Host '  Run Setup-LegacyMCPClient.ps1 on each consultant PC.' -ForegroundColor Yellow
    Write-Host '==========================================' -ForegroundColor Yellow
    Write-Host "  $ApiKey" -ForegroundColor Yellow
    Write-Host '==========================================' -ForegroundColor Yellow
    Write-Host ''
    Write-Info "Setup-LegacyMCPClient.ps1 parameters:"
    Write-Host "  -ApiKey `"$ApiKey`"" -ForegroundColor White
    Write-Host "  -ServerUrl `"https://$serverName`:8000/mcp`"" -ForegroundColor White
    Write-Host "  -CaCertPath `"<path to $certDisplay on consultant PC>`"" -ForegroundColor White
    Write-Host ''
    Write-Host '==========================================' -ForegroundColor White
    Write-Host '  claude_desktop_config.json template' -ForegroundColor White
    Write-Host '  (run Setup-LegacyMCPClient.ps1 -- do not paste API key in the JSON)' -ForegroundColor White
    Write-Host '==========================================' -ForegroundColor White
    Write-Host ''
    Write-Host '{'
    Write-Host '  "mcpServers": {'
    Write-Host '    "legacymcp-live": {'
    Write-Host '      "command": "npx",'
    Write-Host '      "args": ['
    Write-Host '        "mcp-remote",'
    Write-Host "        `"https://$serverName`:8000/mcp`","
    Write-Host '        "--header",'
    Write-Host '        "Authorization:${AUTH_HEADER}"'
    Write-Host '      ],'
    Write-Host '      "env": {'
    Write-Host '        "AUTH_HEADER": "Bearer <run Setup-LegacyMCPClient.ps1>",'
    Write-Host '        "NODE_EXTRA_CA_CERTS": "<run Setup-LegacyMCPClient.ps1>"'
    Write-Host '      }'
    Write-Host '    }'
    Write-Host '  }'
    Write-Host '}'
    Write-Host ''
    Write-Host '==========================================' -ForegroundColor White
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Phase 7 -- Self-check
# ---------------------------------------------------------------------------
Write-Step 'Phase 7 -- Self-check (Config-LegacyMCP.ps1 -Validate)'

$ConfigScript = Join-Path $ScriptDir 'Config-LegacyMCP.ps1'
if (Test-Path $ConfigScript) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ConfigScript -Validate
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host 'Self-check FAILED. Review the [FAIL] items above before using LegacyMCP.' -ForegroundColor Red
        Write-Host "Run '.\installer\Config-LegacyMCP.ps1 -Validate' after resolving issues." -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Warn "Config-LegacyMCP.ps1 not found -- skipping self-check."
}

Write-Host ''
Write-Host 'LegacyMCP installation complete.' -ForegroundColor Green
Write-Host ''
