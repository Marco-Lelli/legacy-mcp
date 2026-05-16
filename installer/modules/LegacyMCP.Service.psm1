# LegacyMCP.Service.psm1
# Windows service management: NSSM install/uninstall, service account,
# firewall rule, EventLog registration.

function Install-LMService {
    [CmdletBinding()]
    param(
        [string]$NssmExe,
        [string]$ServiceName,
        [string]$PythonExe,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [string]$ServiceAccount,
        [string]$LogPath
    )
    throw "Not implemented"
}

function Uninstall-LMService {
    [CmdletBinding()]
    param(
        [string]$NssmExe,
        [string]$ServiceName
    )
    throw "Not implemented"
}

function Add-LMFirewallRule {
    [CmdletBinding()]
    param(
        [string]$RuleName,
        [int]$Port
    )
    throw "Not implemented"
}

function Remove-LMFirewallRule {
    [CmdletBinding()]
    param([string]$RuleName)
    throw "Not implemented"
}

function Register-LMEventLog {
    [CmdletBinding()]
    param(
        [string]$LogName   = 'LegacyMCP',
        [string]$Source    = 'LegacyMCP-Server'
    )
    # Requires elevation -- checks internally, throws if not elevated
    # Idempotent: safe to call multiple times
    # Logic extracted from scripts/Register-EventLog.ps1
    throw "Not implemented"
}

function Unregister-LMEventLog {
    [CmdletBinding()]
    param(
        [string]$LogName = 'LegacyMCP',
        [string]$Source  = 'LegacyMCP-Server'
    )
    throw "Not implemented"
}

Export-ModuleMember -Function *
