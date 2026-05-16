# LegacyMCP.Config.psm1
# Configuration management: registry persistence, API key generation,
# DPAPI-NG encryption, post-install validation, YAML snapshot path.

Import-Module (Join-Path $PSScriptRoot 'LegacyMCP.Common.psm1') -Force -Global

$REG_ROOT    = 'HKLM:\SOFTWARE\LegacyMCP'
$REG_SERVICE = 'HKLM:\SOFTWARE\LegacyMCP\Service'

# ---------------------------------------------------------------------------
# Internal helpers -- not exported
# ---------------------------------------------------------------------------

function Get-LMYamlContent {
    param([string]$ConfigPath)
    if (-not $ConfigPath -or -not (Test-Path $ConfigPath)) { return $null }
    return Get-Content $ConfigPath -Raw -Encoding UTF8
}

function Get-LMYamlSnapshotPath {
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

function Update-LMYamlSnapshotPath {
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

function Get-LMYamlPort {
    param([string]$Content)
    if (-not $Content) { return $null }
    $inServerBlock = $false
    foreach ($line in ($Content -split '\r?\n')) {
        if ($line.TrimEnd() -eq 'server:') { $inServerBlock = $true }
        elseif ($inServerBlock -and $line.Length -gt 0 -and $line[0] -ne ' ' -and $line[0] -ne '#' -and $line[0] -ne "`t") {
            $inServerBlock = $false
        }
        if ($inServerBlock -and $line.TrimStart().StartsWith('port')) {
            $colonIdx = $line.IndexOf(':')
            if ($colonIdx -ge 0) {
                $portVal = 0
                if ([int]::TryParse($line.Substring($colonIdx + 1).Trim(), [ref]$portVal)) { return $portVal }
            }
        }
    }
    return $null
}

function Test-LMYamlHasHost {
    param([string]$Content)
    if (-not $Content) { return $false }
    foreach ($line in ($Content -split '\r?\n')) {
        if ($line.TrimStart().StartsWith('host')) { return $true }
    }
    return $false
}

function Test-LMYamlHasHost0000 {
    param([string]$Content)
    if (-not $Content) { return $false }
    foreach ($line in ($Content -split '\r?\n')) {
        if ($line -match '^\s*host\s*:\s*0\.0\.0\.0') { return $true }
    }
    return $false
}

function Test-LMYamlHasCredentialLeak {
    param([string]$Content)
    if (-not $Content) { return $false }
    return ($Content -match '(?i)(password|secret)\s*:\s*\S')
}

function Test-LMNssmServiceExists {
    $svc = Get-Service -Name 'LegacyMCP' -ErrorAction SilentlyContinue
    return ($null -ne $svc)
}

# ---------------------------------------------------------------------------
# New-LMConfigYaml -- Step 3e scope, not yet implemented
# ---------------------------------------------------------------------------

function New-LMConfigYaml {
    [CmdletBinding()]
    param(
        [string]$TemplatePath,
        [string]$OutputPath,
        [hashtable]$Substitutions,
        [switch]$Force
    )
    throw 'New-LMConfigYaml: not yet implemented (Step 3e scope).'
}

# ---------------------------------------------------------------------------
# Get-LMConfig
# ---------------------------------------------------------------------------

function Get-LMConfig {
    [CmdletBinding()]
    param([string]$RegistryRoot = $REG_ROOT)

    $result = @{}
    if (-not (Test-Path $RegistryRoot)) { return $result }

    $props = Get-ItemProperty -Path $RegistryRoot -ErrorAction SilentlyContinue
    if ($null -eq $props) { return $result }

    foreach ($name in @('InstallPath','Version','ConfigPath','LogPath','Profile','Transport','Port')) {
        if ($null -ne $props.$name) { $result[$name] = $props.$name }
    }

    if ($result.ContainsKey('ConfigPath')) {
        $yamlContent = Get-LMYamlContent -ConfigPath $result['ConfigPath']
        $snapPath    = Get-LMYamlSnapshotPath -Content $yamlContent
        if ($snapPath) { $result['SnapshotPath'] = $snapPath }
    }

    return $result
}

# ---------------------------------------------------------------------------
# Set-LMConfig
# ---------------------------------------------------------------------------

function Set-LMConfig {
    [CmdletBinding()]
    param(
        [string]$RegistryRoot = $REG_ROOT,
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Value
    )

    Assert-LMElevation -Context 'Config Set'

    $vals           = Get-LMConfig -RegistryRoot $RegistryRoot
    $currentProfile = if ($vals.ContainsKey('Profile')) { $vals['Profile'] } else { 'A' }

    switch ($Name) {
        'Transport' {
            $valid = @('stdio','streamable-http','sse')
            if ($valid -notcontains $Value) {
                throw "Invalid Transport value '$Value'. Allowed: $($valid -join ', ')"
            }
            if ($Value -eq 'streamable-http' -and $currentProfile -eq 'A') {
                throw "Transport 'streamable-http' is not compatible with Profile A (stdio only)."
            }
            Set-LMRegistry -Key $RegistryRoot -Name 'Transport' -Value $Value
            Write-LMOK "Transport set to '$Value'."
        }
        'Profile' {
            $valid = @('A','B-core','B-enterprise','C')
            if ($valid -notcontains $Value) {
                throw "Invalid Profile value '$Value'. Allowed: $($valid -join ', ')"
            }
            if ($Value -like 'B*' -and -not (Test-LMNssmServiceExists)) {
                Write-LMWarn "Profile '$Value' requires the LegacyMCP Windows service."
                Write-LMWarn "Run Setup-LegacyMCP.ps1 -Profile $Value to set up the service."
            }
            Set-LMRegistry -Key $RegistryRoot -Name 'Profile' -Value $Value
            Write-LMOK "Profile set to '$Value'."
        }
        'Port' {
            $portInt = 0
            if (-not [int]::TryParse($Value, [ref]$portInt)) {
                throw 'Port must be a numeric value.'
            }
            if ($portInt -lt 1024 -or $portInt -gt 65535) {
                throw "Port $portInt is out of allowed range 1024-65535."
            }
            Set-LMRegistry -Key $RegistryRoot -Name 'Port' -Value $portInt -Type 'DWord'
            Write-LMOK "Port set to $portInt."
        }
        'ConfigPath' {
            if (-not (Test-Path $Value)) { throw "File not found: $Value" }
            Set-LMRegistry -Key $RegistryRoot -Name 'ConfigPath' -Value $Value
            Write-LMOK "ConfigPath set to '$Value'."
        }
        'InstallPath' {
            if (-not (Test-Path $Value)) { throw "Path not found: $Value" }
            Set-LMRegistry -Key $RegistryRoot -Name 'InstallPath' -Value $Value
            Write-LMOK "InstallPath set to '$Value'."
        }
        'LogPath' {
            Set-LMRegistry -Key $RegistryRoot -Name 'LogPath' -Value $Value
            Write-LMOK "LogPath set to '$Value' (directory created by server if absent)."
        }
        'SnapshotPath' {
            if (-not [System.IO.Path]::IsPathRooted($Value)) {
                throw "SnapshotPath must be an absolute path: $Value"
            }
            $cfgPath = if ($vals.ContainsKey('ConfigPath')) { $vals['ConfigPath'] } else { $null }
            if (-not $cfgPath -or -not (Test-Path $cfgPath)) {
                throw 'config.yaml not found. Set ConfigPath first.'
            }
            if (-not (Test-Path $Value)) {
                New-Item -ItemType Directory -Path $Value -Force | Out-Null
                Write-LMOK "Snapshot directory created: $Value"
            }
            $wmiSvc = $null
            try { $wmiSvc = Get-CimInstance Win32_Service -Filter "Name='LegacyMCP'" -ErrorAction SilentlyContinue } catch {}
            if ($wmiSvc -and $wmiSvc.StartName) {
                $svcAcct   = $wmiSvc.StartName
                $icaclsOut = & icacls $Value /grant "${svcAcct}:(M)" 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-LMOK "Write access granted to '$svcAcct' on: $Value"
                } else {
                    throw "Cannot grant write access on '$Value' for '$svcAcct': $icaclsOut"
                }
            }
            Update-LMYamlSnapshotPath -YamlPath $cfgPath -Value $Value
            Write-LMOK "snapshot_path updated in config.yaml: $Value"
        }
        default {
            throw "Unknown key '$Name'. Settable: Transport, Profile, Port, ConfigPath, InstallPath, LogPath, SnapshotPath."
        }
    }
}

# ---------------------------------------------------------------------------
# Test-LMConfig
# ---------------------------------------------------------------------------

function Test-LMConfig {
    [CmdletBinding()]
    param(
        [string]$RegistryRoot = $REG_ROOT,
        [string]$Profile
    )

    $elevated = Test-LMElevation
    if (-not $elevated) {
        Write-LMWarn 'Test-LMConfig: not running as Administrator -- some checks may be skipped.'
    }

    $hasError = $false

    if (-not (Test-Path $RegistryRoot)) {
        Write-LMWarn 'Registry key not found. LegacyMCP may not be formally installed.'
        return $false
    }

    $vals          = Get-LMConfig -RegistryRoot $RegistryRoot
    $deployProfile = if ($Profile) { $Profile } elseif ($vals.ContainsKey('Profile')) { $vals['Profile'] } else { 'A' }
    $transport     = if ($vals.ContainsKey('Transport')) { $vals['Transport'] } else { 'stdio' }
    $port          = if ($vals.ContainsKey('Port'))      { [int]$vals['Port'] } else { 8000 }
    $installPath   = if ($vals.ContainsKey('InstallPath')) { $vals['InstallPath'] } else { $null }
    $configPath    = if ($vals.ContainsKey('ConfigPath'))  { $vals['ConfigPath']  } else { $null }
    $logPath       = if ($vals.ContainsKey('LogPath'))     { $vals['LogPath']     } else { $null }

    Write-LMInfo "Profile: $deployProfile  Transport: $transport  Port: $port"

    if ($deployProfile -eq 'C') {
        Write-LMInfo 'Profile C -- deep validation skipped. Ensure WAF, OAuth2/OIDC, and MFA are configured externally.'
        return $true
    }

    Write-LMInfo '[Common checks]'

    if (-not $installPath) {
        Write-LMFail 'InstallPath not set in registry.'; $hasError = $true
    } elseif (-not (Test-Path $installPath)) {
        Write-LMFail "InstallPath not found: $installPath"; $hasError = $true
    } else {
        Write-LMOK "InstallPath found: $installPath"
    }

    if (-not $configPath) {
        Write-LMFail 'ConfigPath not set in registry.'; $hasError = $true
    } elseif (-not (Test-Path $configPath)) {
        Write-LMFail "ConfigPath not found: $configPath"; $hasError = $true
    } else {
        Write-LMOK "ConfigPath found: $configPath"
    }

    if (-not $logPath) {
        Write-LMFail 'LogPath not set in registry.'; $hasError = $true
    } else {
        if (Test-Path $logPath) {
            Write-LMOK "LogPath found: $logPath"
        } else {
            try {
                New-Item -ItemType Directory -Path $logPath -Force | Out-Null
                Write-LMOK "LogPath created: $logPath"
            } catch {
                Write-LMFail "LogPath not found and cannot be created: $logPath"; $hasError = $true
            }
        }
    }

    if ($port -lt 1024 -or $port -gt 65535) {
        Write-LMFail "Port $port out of range 1024-65535."; $hasError = $true
    } else {
        Write-LMOK "Port $port in valid range."
    }

    if ($logPath -and $installPath -and $logPath.StartsWith($installPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-LMWarn 'LogPath is inside InstallPath -- risk of committing logs to git.'
    }

    $yamlContent = Get-LMYamlContent -ConfigPath $configPath

    if ($yamlContent -and (Test-LMYamlHasCredentialLeak -Content $yamlContent)) {
        Write-LMWarn 'config.yaml may contain credentials in plaintext. Use gMSA or environment variables.'
    }

    if ($deployProfile -eq 'A') {
        Write-LMInfo '[Profile A checks]'

        if ($transport -ne 'stdio') {
            Write-LMFail "Profile A requires Transport 'stdio', found '$transport'."; $hasError = $true
        } else {
            Write-LMOK "Transport is 'stdio' (correct for Profile A)."
        }

        if ($yamlContent -and (Test-LMYamlHasHost -Content $yamlContent)) {
            Write-LMWarn "config.yaml contains 'host:' -- ignored in Profile A but may indicate a wrong template."
        } else {
            Write-LMOK "No 'host:' field in config.yaml (correct for Profile A)."
        }

        if (Test-LMNssmServiceExists) {
            Write-LMWarn "Windows service 'LegacyMCP' exists. Profile A normally runs as a local stdio process."
        }

    } elseif ($deployProfile -like 'B*') {
        Write-LMInfo '[Profile B checks]'

        $regProps = Get-ItemProperty -Path $RegistryRoot -ErrorAction SilentlyContinue
        if ($null -eq $regProps -or [string]::IsNullOrEmpty($regProps.ApiKey)) {
            Write-LMFail 'ApiKey not found in registry. Profile B requires an API key.'; $hasError = $true
        } else {
            Write-LMOK 'ApiKey present in registry (encrypted).'
        }

        if ($transport -ne 'streamable-http') {
            Write-LMFail "Profile B requires Transport 'streamable-http', found '$transport'."; $hasError = $true
        } else {
            Write-LMOK "Transport is 'streamable-http' (correct for Profile B)."
        }

        if ($yamlContent -and -not (Test-LMYamlHasHost0000 -Content $yamlContent)) {
            Write-LMFail "config.yaml does not contain 'host: 0.0.0.0'. Profile B requires binding on all interfaces."
            $hasError = $true
        } elseif ($yamlContent) {
            Write-LMOK "config.yaml contains 'host: 0.0.0.0'."
        }

        if (-not (Test-LMNssmServiceExists)) {
            Write-LMFail "Windows service 'LegacyMCP' not found. Profile B requires NSSM service."; $hasError = $true
        } else {
            Write-LMOK "Windows service 'LegacyMCP' is installed."
        }

        if ($yamlContent) {
            $yamlPort = Get-LMYamlPort -Content $yamlContent
            if ($null -ne $yamlPort -and $yamlPort -ne $port) {
                Write-LMFail "Port mismatch: registry=$port, config.yaml=$yamlPort."; $hasError = $true
            } elseif ($null -ne $yamlPort) {
                Write-LMOK "Port consistent: registry=$port, config.yaml=$yamlPort."
            }
        }

        if ($yamlContent) {
            $snapshotDir = Get-LMYamlSnapshotPath -Content $yamlContent
            if (-not $snapshotDir) {
                Write-LMWarn 'snapshot_path not configured -- server will use default %ProgramData%\LegacyMCP\snapshots.'
            } elseif (-not (Test-Path $snapshotDir)) {
                Write-LMFail "snapshot_path directory not found: $snapshotDir"; $hasError = $true
            } else {
                $testFile = Join-Path $snapshotDir '.legacymcp_write_test'
                try {
                    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                    [System.IO.File]::WriteAllText($testFile, 'test', $utf8NoBom)
                    Remove-Item $testFile -Force -ErrorAction SilentlyContinue
                    Write-LMOK "snapshot_path writable: $snapshotDir"
                } catch {
                    Write-LMFail "snapshot_path not writable: $snapshotDir"; $hasError = $true
                }
            }
        }

        $wmiSvc = $null
        try { $wmiSvc = Get-CimInstance Win32_Service -Filter "Name='LegacyMCP'" -ErrorAction SilentlyContinue } catch {}
        if ($wmiSvc) {
            $runningAs   = $wmiSvc.StartName
            $systemAccts = @('LocalSystem', 'NT AUTHORITY\SYSTEM', 'LocalService', 'NetworkService')
            if ($runningAs -in $systemAccts) {
                Write-LMWarn "Service running as $runningAs -- not suitable for production Live Mode (no Kerberos identity)."
            } else {
                Write-LMOK "Service running as: $runningAs"
                if ($elevated) {
                    $secpolCfg = [System.IO.Path]::GetTempFileName()
                    try {
                        $ntAcct = New-Object System.Security.Principal.NTAccount($runningAs)
                        $sid    = $ntAcct.Translate([System.Security.Principal.SecurityIdentifier]).Value
                        & secedit /export /cfg $secpolCfg /quiet | Out-Null
                        $cfgContent = Get-Content $secpolCfg -Raw -Encoding Unicode
                        if ($cfgContent -match "SeServiceLogonRight\s*=.*\*$sid") {
                            Write-LMOK "ServiceAccount '$runningAs' has 'Log on as a service' right."
                        } else {
                            Write-LMWarn "ServiceAccount '$runningAs' may lack 'Log on as a service' right."
                            Write-LMWarn 'secedit reflects local policy only -- GPO-granted rights may not appear here.'
                        }
                    } catch {
                        Write-LMWarn "Could not verify SeServiceLogonRight for '$runningAs': $_"
                    } finally {
                        if (Test-Path $secpolCfg) { Remove-Item $secpolCfg -Force -ErrorAction SilentlyContinue }
                    }
                } else {
                    Write-LMWarn 'SeServiceLogonRight check skipped -- not running as Administrator.'
                    Write-LMWarn 'secedit reflects local policy only -- GPO-granted rights may not appear. Run as Administrator for accurate results.'
                }
            }
        }
    }

    if ($hasError) {
        Write-LMFail 'Validation FAILED -- one or more checks require attention.'
        return $false
    }
    Write-LMOK 'Validation PASSED -- no blocking issues found.'
    return $true
}

# ---------------------------------------------------------------------------
# New-LMApiKey
# ---------------------------------------------------------------------------

function New-LMApiKey {
    return [System.Guid]::NewGuid().ToString('N')
}

# ---------------------------------------------------------------------------
# Protect-LMApiKey / Get-LMApiKey  (DPAPI-NG via pwsh.exe subprocess)
# ---------------------------------------------------------------------------

function Protect-LMApiKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ApiKey,
        [Parameter(Mandatory)]
        [string]$ServiceAccount,
        [string]$RegistryRoot = $REG_ROOT
    )
    Assert-LMElevation -Context 'Protect-LMApiKey'
    try {
        $svcSid = (New-Object System.Security.Principal.NTAccount($ServiceAccount)).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
        # Pass secrets via env vars to avoid quoting issues in subprocess command string
        $env:_LM_APIKEY = $ApiKey
        $env:_LM_SID    = $svcSid
        $cmd = 'Import-Module SecretManagement.DpapiNG -ErrorAction Stop; ConvertTo-DpapiNGSecret -InputObject $env:_LM_APIKEY -Sid $env:_LM_SID'
        $encryptedKey = & pwsh.exe -NoProfile -NonInteractive -Command $cmd
        if ($LASTEXITCODE -ne 0 -or -not $encryptedKey) {
            throw "DPAPI-NG encryption failed (exit $LASTEXITCODE)."
        }
        Set-LMRegistry -Key $RegistryRoot -Name 'ApiKey' -Value $encryptedKey
        Write-LMOK 'API key stored encrypted (DPAPI-NG, SID-scoped) in registry.'
    } finally {
        $env:_LM_APIKEY = $null
        $env:_LM_SID    = $null
    }
}

function Get-LMApiKey {
    [CmdletBinding()]
    param([string]$RegistryRoot = $REG_ROOT)
    $props = Get-ItemProperty -Path $RegistryRoot -ErrorAction SilentlyContinue
    if ($null -eq $props -or [string]::IsNullOrEmpty($props.ApiKey)) { return $null }
    $env:_LM_ENCKEY = $props.ApiKey
    try {
        $cmd       = 'Import-Module SecretManagement.DpapiNG -ErrorAction Stop; ConvertFrom-DpapiNGSecret -InputObject $env:_LM_ENCKEY'
        $plaintext = & pwsh.exe -NoProfile -NonInteractive -Command $cmd
        if ($LASTEXITCODE -ne 0) { return $null }
        return $plaintext
    } finally {
        $env:_LM_ENCKEY = $null
    }
}

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

Export-ModuleMember -Function Get-LMConfig, Set-LMConfig, Test-LMConfig,
                              New-LMApiKey, Protect-LMApiKey, Get-LMApiKey
