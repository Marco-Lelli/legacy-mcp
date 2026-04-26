#Requires -Version 5.1
<#
.SYNOPSIS
    LegacyMCP configuration management -- read, set, and validate the
    Windows registry configuration stored under HKLM\SOFTWARE\LegacyMCP\.

.DESCRIPTION
    Three operating modes:

      -Get            Read all registry values and show path-existence status.
      -Set <K> <V>    Write a single value with inline validation.
      -Validate       Check configuration coherence for the active profile.

.EXAMPLE
    .\Config-LegacyMCP.ps1 -Get
    .\Config-LegacyMCP.ps1 -Set Transport streamable-http
    .\Config-LegacyMCP.ps1 -Validate
#>

[CmdletBinding(DefaultParameterSetName = 'Get')]
param(
    [Parameter(ParameterSetName = 'Get', Mandatory = $true)]
    [switch]$Get,

    [Parameter(ParameterSetName = 'Set', Mandatory = $true)]
    [switch]$Set,

    [Parameter(ParameterSetName = 'Set', Mandatory = $true, Position = 0)]
    [string]$Key,

    [Parameter(ParameterSetName = 'Set', Mandatory = $true, Position = 1)]
    [string]$Value,

    [Parameter(ParameterSetName = 'Validate', Mandatory = $true)]
    [switch]$Validate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$REG_ROOT    = 'HKLM:\SOFTWARE\LegacyMCP'
$REG_SERVICE = 'HKLM:\SOFTWARE\LegacyMCP\Service'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-OK {
    param([string]$Message)
    Write-Host "  [OK]   $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [INFO] $Message" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Registry helpers
# ---------------------------------------------------------------------------
function Test-RegistryKeyExists {
    return Test-Path $REG_ROOT
}

function Get-RegistryValues {
    if (-not (Test-RegistryKeyExists)) {
        return @{}
    }
    $props = Get-ItemProperty -Path $REG_ROOT -ErrorAction SilentlyContinue
    if (-not $props) { return @{} }
    $result = @{}
    foreach ($name in @('InstallPath','Version','ConfigPath','LogPath','Profile','Transport','Port')) {
        $v = $props.$name
        if ($null -ne $v) { $result[$name] = $v }
    }
    return $result
}

function Get-RegistryServiceValues {
    if (-not (Test-Path $REG_SERVICE)) { return @{} }
    $props = Get-ItemProperty -Path $REG_SERVICE -ErrorAction SilentlyContinue
    if (-not $props) { return @{} }
    $result = @{}
    foreach ($name in @('AutoStart')) {
        $v = $props.$name
        if ($null -ne $v) { $result[$name] = $v }
    }
    return $result
}

function Set-RegistryValue {
    param([string]$Name, $Value, [string]$Type = 'String')
    if (-not (Test-RegistryKeyExists)) {
        New-Item -Path $REG_ROOT -Force | Out-Null
    }
    Set-ItemProperty -Path $REG_ROOT -Name $Name -Value $Value -Type $Type
}

# ---------------------------------------------------------------------------
# NSSM service check
# ---------------------------------------------------------------------------
function Test-NssmServiceExists {
    $svc = Get-Service -Name 'LegacyMCP' -ErrorAction SilentlyContinue
    return ($null -ne $svc)
}

# ---------------------------------------------------------------------------
# config.yaml helpers
# ---------------------------------------------------------------------------
function Get-ConfigYamlContent {
    param([string]$ConfigPath)
    if (-not $ConfigPath -or -not (Test-Path $ConfigPath)) { return $null }
    return Get-Content -Path $ConfigPath -Raw -Encoding UTF8
}

function Test-ConfigYamlHasHost {
    param([string]$Content)
    if (-not $Content) { return $false }
    # Look for "host:" that is not commented out
    return ($Content -match '(?m)^\s*host\s*:')
}

function Test-ConfigYamlHasHost0000 {
    param([string]$Content)
    if (-not $Content) { return $false }
    return ($Content -match '(?m)^\s*host\s*:\s*0\.0\.0\.0')
}

function Get-ConfigYamlPort {
    param([string]$Content)
    if (-not $Content) { return $null }
    if ($Content -match '(?m)^\s*port\s*:\s*(\d+)') {
        return [int]$Matches[1]
    }
    return $null
}

function Test-ConfigYamlHasCredentialLeak {
    param([string]$Content)
    if (-not $Content) { return $false }
    # Detect uncommented lines with password/secret followed by a value
    return ($Content -match '(?im)^\s*(password|secret)\s*:')
}

function Get-ConfigYamlSnapshotPath {
    param([string]$Content)
    if (-not $Content) { return $null }
    $inServerBlock = $false
    foreach ($line in ($Content -split '\r?\n')) {
        if ($line.TrimEnd() -eq 'server:') {
            $inServerBlock = $true
        } elseif ($inServerBlock -and $line.Length -gt 0 -and $line[0] -ne ' ' -and $line[0] -ne '#' -and $line[0] -ne "`t") {
            $inServerBlock = $false
        }
        if ($inServerBlock -and $line.TrimStart().StartsWith('snapshot_path')) {
            $colonIdx = $line.IndexOf(':')
            if ($colonIdx -ge 0) { return $line.Substring($colonIdx + 1).Trim() }
        }
    }
    return $null
}

function Set-SnapshotPathInYaml {
    param([string]$YamlPath, [string]$Value)
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
    $newLine = "  snapshot_path: $Value"
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
# MODE: -Get
# ---------------------------------------------------------------------------
function Invoke-Get {
    Write-Host ''
    Write-Host 'LegacyMCP -- Registry Configuration' -ForegroundColor White
    Write-Host ('  Registry key: ' + $REG_ROOT)
    Write-Host ''

    if (-not (Test-RegistryKeyExists)) {
        Write-Host '  (key not found -- LegacyMCP may not be formally installed)' -ForegroundColor Yellow
        Write-Host ''
        return
    }

    $vals = Get-RegistryValues
    $svc  = Get-RegistryServiceValues

    $pathFields = @('InstallPath','ConfigPath','LogPath')

    foreach ($name in @('InstallPath','Version','ConfigPath','LogPath','Profile','Transport','Port')) {
        $v = if ($vals.ContainsKey($name)) { $vals[$name] } else { '(not set)' }
        $line = "  {0,-22} {1}" -f ($name + ':'), $v

        if ($pathFields -contains $name -and $vals.ContainsKey($name)) {
            if (Test-Path $vals[$name]) {
                $line += '  [FILE OK]'
            } else {
                $line += '  [FILE NOT FOUND]'
            }
        }
        Write-Host $line
    }

    # Show snapshot_path from config.yaml (not stored in registry)
    if ($vals.ContainsKey('ConfigPath')) {
        $cfgContent = Get-ConfigYamlContent -ConfigPath $vals['ConfigPath']
        $snapPath   = Get-ConfigYamlSnapshotPath -Content $cfgContent
        if ($snapPath) {
            $snapLine = "  {0,-22} {1}" -f 'snapshot_path:', $snapPath
            if (Test-Path $snapPath) {
                $snapLine += '  [DIR OK]'
            } else {
                $snapLine += '  [DIR NOT FOUND]'
            }
            Write-Host $snapLine
        }
    }

    if ($svc.Count -gt 0) {
        Write-Host ''
        Write-Host '  Service sub-key:'
        foreach ($name in @('AutoStart')) {
            if ($svc.ContainsKey($name)) {
                $line = "  {0,-22} {1}" -f ($name + ':'), $svc[$name]
                Write-Host $line
            }
        }
    }

    Write-Host ''
}

# ---------------------------------------------------------------------------
# MODE: -Set
# ---------------------------------------------------------------------------
function Invoke-Set {
    param([string]$Key, [string]$Value)

    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host '  [FAIL] Config-LegacyMCP.ps1 -Set requires Administrator privileges. Re-run as Administrator.' -ForegroundColor Red
        exit 1
    }

    $vals = Get-RegistryValues
    $currentProfile = if ($vals.ContainsKey('Profile')) { $vals['Profile'] } else { 'A' }

    switch ($Key) {

        'Transport' {
            $valid = @('stdio','streamable-http','sse')
            if ($valid -notcontains $Value) {
                Write-Fail "Invalid Transport value '$Value'. Allowed: $($valid -join ', ')"
                exit 1
            }
            if ($Value -eq 'streamable-http' -and $currentProfile -eq 'A') {
                Write-Fail "Transport 'streamable-http' is not compatible with Profile A (stdio only)."
                exit 1
            }
            Set-RegistryValue -Name 'Transport' -Value $Value
            Write-OK "Transport set to '$Value'."
        }

        'Profile' {
            $valid = @('A','B-core','B-enterprise','C')
            if ($valid -notcontains $Value) {
                Write-Fail "Invalid Profile value '$Value'. Allowed: $($valid -join ', ')"
                exit 1
            }
            if ($Value -eq 'C') {
                Write-Info "Profile C is an enterprise deployment. Manual configuration required."
                Write-Info "Registry value updated. No automatic service or transport changes applied."
                Set-RegistryValue -Name 'Profile' -Value $Value
                return
            }
            if ($Value -like 'B*' -and -not (Test-NssmServiceExists)) {
                Write-Warn "Profile '$Value' requires the LegacyMCP Windows service (NSSM)."
                Write-Warn "Run Install-LegacyMCP.ps1 -DeployProfile B to set up the service."
            }
            Set-RegistryValue -Name 'Profile' -Value $Value
            Write-OK "Profile set to '$Value'."
        }

        'Port' {
            $portInt = 0
            if (-not [int]::TryParse($Value, [ref]$portInt)) {
                Write-Fail "Port must be a numeric value."
                exit 1
            }
            if ($portInt -lt 1024 -or $portInt -gt 65535) {
                Write-Fail "Port $portInt is out of allowed range 1024-65535."
                exit 1
            }
            Set-RegistryValue -Name 'Port' -Value $portInt -Type 'DWord'
            Write-OK "Port set to $portInt."
        }

        'ConfigPath' {
            if (-not (Test-Path $Value)) {
                Write-Fail "File not found: $Value"
                exit 1
            }
            Set-RegistryValue -Name 'ConfigPath' -Value $Value
            Write-OK "ConfigPath set to '$Value'."
        }

        'InstallPath' {
            if (-not (Test-Path $Value)) {
                Write-Fail "Path not found: $Value"
                exit 1
            }
            Set-RegistryValue -Name 'InstallPath' -Value $Value
            Write-OK "InstallPath set to '$Value'."
        }

        'LogPath' {
            Set-RegistryValue -Name 'LogPath' -Value $Value
            Write-OK "LogPath set to '$Value' (directory will be created by the server if absent)."
        }

        'SnapshotPath' {
            if (-not [System.IO.Path]::IsPathRooted($Value)) {
                Write-Fail "SnapshotPath must be an absolute path: $Value"
                exit 1
            }
            $cfgPath = if ($vals.ContainsKey('ConfigPath')) { $vals['ConfigPath'] } else { $null }
            if (-not $cfgPath -or -not (Test-Path $cfgPath)) {
                Write-Fail 'config.yaml not found. Set ConfigPath first or re-run Install-LegacyMCP.ps1.'
                exit 1
            }
            try {
                if (-not (Test-Path $Value)) {
                    New-Item -ItemType Directory -Path $Value -Force | Out-Null
                    Write-OK "Snapshot directory created: $Value"
                }
            } catch {
                Write-Fail "Cannot create snapshot directory '$Value': $_"
                exit 1
            }
            # Grant write access to the service account if the LegacyMCP service exists
            $wmiSvc = $null
            try {
                $wmiSvc = Get-CimInstance Win32_Service -Filter "Name='LegacyMCP'" -ErrorAction SilentlyContinue
                if (-not $wmiSvc) { $wmiSvc = Get-WmiObject Win32_Service -Filter "Name='LegacyMCP'" -ErrorAction SilentlyContinue }
            } catch {}
            if ($wmiSvc -and $wmiSvc.StartName) {
                $svcAcct   = $wmiSvc.StartName
                try {
                    $icaclsOut = & icacls $Value /grant "${svcAcct}:(M)" 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-OK "Write access granted to '$svcAcct' on: $Value"
                    } else {
                        Write-Fail "Cannot grant write access on '$Value' for '$svcAcct': $icaclsOut"
                        exit 1
                    }
                } catch {
                    Write-Fail "Error setting permissions on '$Value': $_"
                    exit 1
                }
            }
            try {
                Set-SnapshotPathInYaml -YamlPath $cfgPath -Value $Value
                Write-OK "snapshot_path updated in config.yaml: $Value"
            } catch {
                Write-Fail "Cannot update config.yaml: $_"
                exit 1
            }
        }

        default {
            Write-Fail "Unknown key '$Key'. Settable keys: Transport, Profile, Port, ConfigPath, InstallPath, LogPath, SnapshotPath."
            exit 1
        }
    }
}

# ---------------------------------------------------------------------------
# MODE: -Validate
# ---------------------------------------------------------------------------
function Invoke-Validate {
    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host '  [FAIL] Config-LegacyMCP.ps1 -Validate requires Administrator privileges. Re-run as Administrator.' -ForegroundColor Red
        exit 1
    }

    Write-Host ''
    Write-Host 'LegacyMCP -- Configuration Validation' -ForegroundColor White
    Write-Host ''

    $hasError = $false

    if (-not (Test-RegistryKeyExists)) {
        Write-Warn 'Registry key not found. LegacyMCP may not be formally installed.'
        Write-Warn 'Run Install-LegacyMCP.ps1 to create the registry configuration.'
        Write-Host ''
        exit 0
    }

    $vals    = Get-RegistryValues
    $svc     = Get-RegistryServiceValues
    $deployProfile = if ($vals.ContainsKey('Profile'))   { $vals['Profile']   } else { 'A' }
    $transport = if ($vals.ContainsKey('Transport')) { $vals['Transport'] } else { 'stdio' }
    $port    = if ($vals.ContainsKey('Port'))      { [int]$vals['Port'] } else { 8000 }
    $installPath = if ($vals.ContainsKey('InstallPath')) { $vals['InstallPath'] } else { $null }
    $configPath  = if ($vals.ContainsKey('ConfigPath'))  { $vals['ConfigPath']  } else { $null }
    $logPath     = if ($vals.ContainsKey('LogPath'))     { $vals['LogPath']     } else { $null }

    Write-Host "  Profile  : $deployProfile"
    Write-Host "  Transport: $transport"
    Write-Host "  Port     : $port"
    Write-Host ''

    # ------------------------------------------------------------------
    # Profile C -- skip deep validation
    # ------------------------------------------------------------------
    if ($deployProfile -eq 'C') {
        Write-Info "Profile C (enterprise deployment) -- deep validation skipped."
        Write-Info "Ensure WAF, OAuth2/OIDC, and MFA are configured externally."
        Write-Host ''
        exit 0
    }

    # ------------------------------------------------------------------
    # Common checks -- paths and port range
    # ------------------------------------------------------------------
    Write-Host '  [Common checks]'

    # InstallPath
    if (-not $installPath) {
        Write-Fail 'InstallPath not set in registry.'
        $hasError = $true
    } elseif (-not (Test-Path $installPath)) {
        Write-Fail "InstallPath not found on filesystem: $installPath"
        $hasError = $true
    } else {
        Write-OK "InstallPath found: $installPath"
    }

    # ConfigPath
    if (-not $configPath) {
        Write-Fail 'ConfigPath not set in registry.'
        $hasError = $true
    } elseif (-not (Test-Path $configPath)) {
        Write-Fail "ConfigPath not found or not readable: $configPath"
        $hasError = $true
    } else {
        Write-OK "ConfigPath found: $configPath"
    }

    # LogPath
    if (-not $logPath) {
        Write-Fail 'LogPath not set in registry.'
        $hasError = $true
    } else {
        if (Test-Path $logPath) {
            Write-OK "LogPath found: $logPath"
        } else {
            # Try to create it
            try {
                New-Item -ItemType Directory -Path $logPath -Force | Out-Null
                Write-OK "LogPath created: $logPath"
            } catch {
                Write-Fail "LogPath not found and cannot be created: $logPath"
                $hasError = $true
            }
        }
    }

    # Port range
    if ($port -lt 1024 -or $port -gt 65535) {
        Write-Fail "Port $port is out of allowed range 1024-65535."
        $hasError = $true
    } else {
        Write-OK "Port $port is in valid range."
    }

    # LogPath inside InstallPath (git commit risk)
    if ($logPath -and $installPath -and $logPath.StartsWith($installPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Warn "LogPath is inside InstallPath -- risk of accidentally committing log files to git."
        Write-Warn "Consider moving logs outside the installation directory."
    }

    # Credential leak in config.yaml
    if ($configPath -and (Test-Path $configPath)) {
        $yamlContent = Get-ConfigYamlContent -ConfigPath $configPath
        if (Test-ConfigYamlHasCredentialLeak -Content $yamlContent) {
            Write-Warn "config.yaml appears to contain a 'password' or 'secret' field in clear text."
            Write-Warn "Use gMSA or environment variables. Never hardcode credentials."
        }
    }

    Write-Host ''

    # ------------------------------------------------------------------
    # Profile-specific checks
    # ------------------------------------------------------------------
    $yamlContent = if ($configPath -and (Test-Path $configPath)) {
        Get-ConfigYamlContent -ConfigPath $configPath
    } else { $null }

    if ($deployProfile -eq 'A') {
        Write-Host '  [Profile A checks]'

        if ($transport -ne 'stdio') {
            Write-Fail "Profile A requires Transport 'stdio', found '$transport'."
            $hasError = $true
        } else {
            Write-OK "Transport is 'stdio' (correct for Profile A)."
        }

        if ($yamlContent -and (Test-ConfigYamlHasHost -Content $yamlContent)) {
            Write-Warn "config.yaml contains a 'host:' entry. Profile A uses stdio -- the host field is ignored but may indicate a copy from a B/C template."
        } else {
            Write-OK "No 'host:' field in config.yaml (correct for Profile A)."
        }

        if (Test-NssmServiceExists) {
            Write-Warn "Windows service 'LegacyMCP' exists. Profile A normally runs as a local stdio process, not a service."
        }

    } elseif ($deployProfile -like 'B*') {
        Write-Host '  [Profile B checks]'

        if ($transport -ne 'streamable-http') {
            Write-Fail "Profile B requires Transport 'streamable-http', found '$transport'."
            $hasError = $true
        } else {
            Write-OK "Transport is 'streamable-http' (correct for Profile B)."
        }

        if ($yamlContent -and -not (Test-ConfigYamlHasHost0000 -Content $yamlContent)) {
            Write-Fail "config.yaml does not contain 'host: 0.0.0.0'. Profile B requires binding on all interfaces."
            $hasError = $true
        } elseif ($yamlContent) {
            Write-OK "config.yaml contains 'host: 0.0.0.0'."
        }

        if (-not (Test-NssmServiceExists)) {
            Write-Fail "Windows service 'LegacyMCP' not found. Profile B requires NSSM service. Run Install-LegacyMCP.ps1 -DeployProfile B."
            $hasError = $true
        } else {
            Write-OK "Windows service 'LegacyMCP' is installed."
        }

        # Port consistency: registry vs config.yaml
        if ($yamlContent) {
            $yamlPort = Get-ConfigYamlPort -Content $yamlContent
            if ($null -ne $yamlPort -and $yamlPort -ne $port) {
                Write-Fail "Port mismatch: registry=$port, config.yaml=$yamlPort. Synchronise the values."
                $hasError = $true
            } elseif ($null -ne $yamlPort) {
                Write-OK "Port is consistent between registry ($port) and config.yaml ($yamlPort)."
            }
        }

        # snapshot_path check
        if ($yamlContent) {
            $snapshotDir = Get-ConfigYamlSnapshotPath -Content $yamlContent
            if (-not $snapshotDir) {
                Write-Warn "snapshot_path not configured in config.yaml -- server will use default C:\LegacyMCP-Data\snapshots\"
            } elseif (-not (Test-Path $snapshotDir)) {
                Write-Fail "snapshot_path directory not found: $snapshotDir"
                $hasError = $true
            } else {
                $testFile  = Join-Path $snapshotDir '.legacymcp_write_test'
                try {
                    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                    [System.IO.File]::WriteAllText($testFile, 'test', $utf8NoBom)
                    Remove-Item $testFile -Force -ErrorAction SilentlyContinue
                    Write-OK "snapshot_path is writable: $snapshotDir"
                } catch {
                    Write-Fail "snapshot_path is not writable: $snapshotDir"
                    $hasError = $true
                }
            }
        }

        # Service account -- query SCM directly (not registry)
        $wmiSvc = $null
        try { $wmiSvc = Get-CimInstance Win32_Service -Filter "Name='LegacyMCP'" } catch {}
        if (-not $wmiSvc) { $wmiSvc = Get-WmiObject Win32_Service -Filter "Name='LegacyMCP'" }
        if ($wmiSvc) {
            $runningAs   = $wmiSvc.StartName
            $systemAccts = @('LocalSystem', 'NT AUTHORITY\SYSTEM', 'LocalService', 'NetworkService')
            if ($runningAs -in $systemAccts) {
                Write-Warn "Service running as $runningAs -- acceptable for testing, NOT suitable for production Live Mode (no Kerberos identity)"
            } else {
                Write-OK "Service running as: $runningAs"

                # SeServiceLogonRight check -- non-system accounts must have this
                # right to start a Windows service after reboot.
                $secpolCfg = Join-Path $env:TEMP 'legacymcp_secpol_val.cfg'
                try {
                    $ntAcct = New-Object System.Security.Principal.NTAccount($runningAs)
                    $sid    = $ntAcct.Translate([System.Security.Principal.SecurityIdentifier]).Value
                    & secedit /export /cfg $secpolCfg /quiet | Out-Null
                    $cfgContent = Get-Content $secpolCfg -Raw -Encoding Unicode
                    if ($cfgContent -match "SeServiceLogonRight\s*=.*\*$sid") {
                        Write-OK "ServiceAccount '$runningAs' has 'Log on as a service' right."
                    } else {
                        Write-Warn "ServiceAccount '$runningAs' may lack 'Log on as a service' right -- verify in secpol.msc"
                    }
                } catch {
                    Write-Warn "Could not verify SeServiceLogonRight for '$runningAs': $_"
                } finally {
                    if (Test-Path $secpolCfg) { Remove-Item $secpolCfg -Force -ErrorAction SilentlyContinue }
                }
            }
        }
    }

    Write-Host ''

    if ($hasError) {
        Write-Host '  Validation FAILED -- one or more [FAIL] items require attention.' -ForegroundColor Red
        Write-Host ''
        exit 1
    } else {
        Write-Host '  Validation PASSED -- no blocking issues found.' -ForegroundColor Green
        Write-Host ''
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
switch ($PSCmdlet.ParameterSetName) {
    'Get'      { Invoke-Get }
    'Set'      { Invoke-Set -Key $Key -Value $Value }
    'Validate' { Invoke-Validate }
}
