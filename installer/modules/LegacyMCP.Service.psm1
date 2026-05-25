# LegacyMCP.Service.psm1
# Windows service management: NSSM install/uninstall, service account,
# firewall rule, EventLog registration.

Import-Module (Join-Path $PSScriptRoot 'LegacyMCP.Common.psm1') -Force -Global

function Install-LMService {
    [CmdletBinding()]
    param(
        [string]$NssmExe,
        [string]$ServiceName,
        [string]$PythonExe,
        [string]$ConfigPath,
        [string]$InstallPath,
        [string]$LogPath,
        [string]$ServiceAccount,
        [int]$Port = 8000
    )
    Assert-LMElevation -Context 'Service installation'

    # Stop + remove existing service (idempotent)
    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-LMInfo "Removing existing '$ServiceName' service for clean reinstall..."
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        & $NssmExe remove $ServiceName confirm
        if ($LASTEXITCODE -ne 0) {
            throw "NSSM failed to remove existing service '$ServiceName'. Exit code: $LASTEXITCODE"
        }
    }

    # Install service
    $NssmArgs = "-m legacy_mcp.server --config `"$ConfigPath`" --transport streamable-http"
    & $NssmExe install $ServiceName $PythonExe
    if ($LASTEXITCODE -ne 0) { throw "NSSM install failed. Exit code: $LASTEXITCODE" }

    & $NssmExe set $ServiceName AppParameters  $NssmArgs
    if ($LASTEXITCODE -ne 0) { throw "NSSM set AppParameters failed. Exit code: $LASTEXITCODE" }
    & $NssmExe set $ServiceName AppDirectory   $InstallPath
    if ($LASTEXITCODE -ne 0) { throw "NSSM set AppDirectory failed. Exit code: $LASTEXITCODE" }
    & $NssmExe set $ServiceName Description    'Legacy MCP Server for Active Directory (Profile B)'
    if ($LASTEXITCODE -ne 0) { throw "NSSM set Description failed. Exit code: $LASTEXITCODE" }
    & $NssmExe set $ServiceName Start          SERVICE_AUTO_START
    if ($LASTEXITCODE -ne 0) { throw "NSSM set Start failed. Exit code: $LASTEXITCODE" }
    & $NssmExe set $ServiceName AppStdout      (Join-Path $LogPath 'legacymcp.log')
    if ($LASTEXITCODE -ne 0) { throw "NSSM set AppStdout failed. Exit code: $LASTEXITCODE" }
    & $NssmExe set $ServiceName AppStderr      (Join-Path $LogPath 'legacymcp-error.log')
    if ($LASTEXITCODE -ne 0) { throw "NSSM set AppStderr failed. Exit code: $LASTEXITCODE" }

    # Service account
    if ($ServiceAccount.EndsWith('$')) {
        & $NssmExe set $ServiceName ObjectName $ServiceAccount ""
        if ($LASTEXITCODE -ne 0) { throw "NSSM set ObjectName (gMSA) failed. Exit code: $LASTEXITCODE" }
        Write-LMOK "Service account set to gMSA: $ServiceAccount"
    } else {
        Write-LMWarn "Using explicit credentials for service account '$ServiceAccount'."
        Write-LMWarn "Recommendation: use a gMSA account to avoid password management. See docs/minimum-permissions.md."
        $svcSecure   = $null
        $svcPassword = $null
        try {
            $svcSecure   = Read-Host "Password for $ServiceAccount" -AsSecureString
            $svcBstr     = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($svcSecure)
            try {
                $svcPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($svcBstr)
            } finally {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($svcBstr)
            }
            & $NssmExe set $ServiceName ObjectName $ServiceAccount $svcPassword
            if ($LASTEXITCODE -ne 0) { throw "NSSM set ObjectName failed. Exit code: $LASTEXITCODE" }
        } catch {
            throw "Failed to set service account credentials: $_"
        } finally {
            if ($svcSecure)   { $svcSecure.Dispose() }
            if ($svcPassword) { $svcPassword = $null }
        }
        Write-LMOK "Service account set to: $ServiceAccount"

        # SeServiceLogonRight check -- non-gMSA accounts must have this right
        # to start a Windows service. gMSA receive it automatically from AD.
        Write-LMInfo "Checking 'Log on as a service' right for: $ServiceAccount"

        $secpolCfg = Join-Path $env:TEMP 'legacymcp_secpol.cfg'
        $seceditDb  = Join-Path $env:TEMP 'legacymcp_secedit.sdb'

        try {
            $ntAcct = New-Object System.Security.Principal.NTAccount($ServiceAccount)
            $sid    = $ntAcct.Translate([System.Security.Principal.SecurityIdentifier]).Value

            & secedit /export /cfg $secpolCfg /quiet | Out-Null
            $cfgContent = Get-Content $secpolCfg -Raw -Encoding Unicode

            if ($cfgContent -match "SeServiceLogonRight\s*=.*\*$sid") {
                Write-LMOK "Account has 'Log on as a service' right."
            } else {
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
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "Install-LMService: secedit /configure failed (exit $LASTEXITCODE) granting SeServiceLogonRight to '$ServiceAccount'. Grant manually via secpol.msc."
                    exit 1
                }
                Write-LMWarn "Granted 'Log on as a service' to $ServiceAccount -- verify in secpol.msc before production deployment"
            }
        } catch {
            Write-LMWarn "Could not check SeServiceLogonRight: $_"
        } finally {
            if (Test-Path $secpolCfg) { Remove-Item $secpolCfg -Force -ErrorAction SilentlyContinue }
            if (Test-Path $seceditDb)  { Remove-Item $seceditDb  -Force -ErrorAction SilentlyContinue }
        }
    }

    Write-LMOK "Service '$ServiceName' installed via NSSM."
}

function Uninstall-LMService {
    [CmdletBinding()]
    param(
        [string]$NssmExe,
        [string]$ServiceName,
        [string]$VenvPath,
        [string]$RegistryRoot = 'HKLM:\SOFTWARE\LegacyMCP'
    )
    Assert-LMElevation -Context 'Service uninstallation'

    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-LMInfo "Service '$ServiceName' not found -- skipping."
        return
    }

    Write-LMInfo "Stopping service '$ServiceName'..."
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue

    if ($NssmExe -and (Test-Path $NssmExe)) {
        & $NssmExe remove $ServiceName confirm
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Uninstall-LMService: NSSM failed to remove service '$ServiceName'. Exit code: $LASTEXITCODE"
            exit 1
        }
        Write-LMOK "Service '$ServiceName' removed via NSSM."
    } else {
        Write-LMInfo "nssm.exe not found -- using sc.exe."
        & sc.exe delete $ServiceName | Out-Null
        Write-LMOK "Service '$ServiceName' removed via sc.exe."
    }

    if ($VenvPath -and (Test-Path $VenvPath)) {
        $regProps         = Get-ItemProperty -Path $RegistryRoot -ErrorAction SilentlyContinue
        $installMode      = if ($regProps) { $regProps.InstallMode }      else { $null }
        $installedVersion = if ($regProps) { $regProps.InstalledVersion } else { $null }
        $versionLabel     = if ($installedVersion) { $installedVersion } else { 'unknown' }
        Write-LMInfo "Uninstalling legacy-mcp package (mode: $installMode, version: $versionLabel)..."
        $venvPython = Join-Path $VenvPath 'Scripts\python.exe'
        if (Test-Path $venvPython) {
            try {
                & $venvPython -m pip uninstall legacy-mcp -y 2>&1 | Out-Null
                Write-LMOK 'legacy-mcp package uninstalled.'
            } catch {
                Write-LMWarn "Could not uninstall legacy-mcp package: $_"
            }
        } else {
            Write-LMWarn 'Python not found in venv -- package uninstall skipped.'
        }
    }
}

function Add-LMFirewallRule {
    [CmdletBinding()]
    param(
        [string]$RuleName = 'LegacyMCP MCP Server',
        [int]$Port
    )
    $existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-LMInfo "Firewall rule '$RuleName' already exists -- skipping."
        return
    }
    try {
        New-NetFirewallRule `
            -DisplayName $RuleName `
            -Direction   Inbound `
            -Protocol    TCP `
            -LocalPort   $Port `
            -Action      Allow `
            -Profile     Domain,Private | Out-Null
        Write-LMOK "Firewall rule created: allow TCP inbound port $Port (Domain, Private)."
    } catch {
        Write-LMWarn "Could not create firewall rule: $_"
        Write-LMWarn "Create manually: New-NetFirewallRule -DisplayName '$RuleName' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Domain,Private"
    }
}

function Remove-LMFirewallRule {
    [CmdletBinding()]
    param([string]$RuleName = 'LegacyMCP MCP Server')
    $existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    if ($existing) {
        try {
            Remove-NetFirewallRule -DisplayName $RuleName
            Write-LMOK "Firewall rule '$RuleName' removed."
        } catch {
            Write-LMWarn "Remove-LMFirewallRule: Could not remove firewall rule '$RuleName': $_"
        }
    } else {
        Write-LMInfo "Firewall rule '$RuleName' not found -- skipping."
    }
}

function Register-LMEventLog {
    [CmdletBinding()]
    param(
        [string]$LogName = 'LegacyMCP',
        [string]$Source  = 'LegacyMCP-Server'
    )
    # Source name must differ from log name --
    # Windows does not allow deleting a source whose name equals the log name.
    Assert-LMElevation -Context 'EventLog registration'
    try {
        if ([System.Diagnostics.EventLog]::SourceExists($Source)) {
            Write-LMInfo "EventLog source '$Source' already registered."
        } else {
            New-EventLog -LogName $LogName -Source $Source
            Write-LMOK "EventLog source '$Source' registered in log '$LogName'."
        }
    } catch {
        throw "Failed to register EventLog source '$Source': $_"
    }
}

function Unregister-LMEventLog {
    [CmdletBinding()]
    param(
        [string]$LogName = 'LegacyMCP',
        [string]$Source  = 'LegacyMCP-Server'
    )
    Assert-LMElevation -Context 'EventLog unregistration'
    try {
        if ([System.Diagnostics.EventLog]::Exists($LogName)) {
            Remove-EventLog -LogName $LogName -ErrorAction Stop
            Write-LMOK "EventLog log '$LogName' and all sources removed."
        } else {
            Write-LMInfo "EventLog log '$LogName' not found -- skipping."
        }
    } catch {
        Write-LMWarn "Could not remove EventLog log '$LogName': $_"
    }
}

Export-ModuleMember -Function *
