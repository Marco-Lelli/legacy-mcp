# LegacyMCP.Config.psm1
# Configuration management: config.yaml read/write, registry persistence,
# API key generation and DPAPI encryption, post-install validation.

function New-LMConfigYaml {
    [CmdletBinding()]
    param(
        [string]$TemplatePath,
        [string]$OutputPath,
        [hashtable]$Substitutions,
        [switch]$Force
    )
    # Creates config.yaml from template
    # If OutputPath exists and -Force not specified: prompts for confirmation
    # (bug field session #38: silent overwrite must not happen)
    throw "Not implemented"
}

function Get-LMConfig {
    [CmdletBinding()]
    param([string]$RegistryRoot = 'HKLM:\SOFTWARE\LegacyMCP')
    throw "Not implemented"
}

function Set-LMConfig {
    [CmdletBinding()]
    param(
        [string]$RegistryRoot = 'HKLM:\SOFTWARE\LegacyMCP',
        [string]$Name,
        [object]$Value
    )
    throw "Not implemented"
}

function Test-LMConfig {
    [CmdletBinding()]
    param(
        [string]$RegistryRoot = 'HKLM:\SOFTWARE\LegacyMCP',
        [string]$Profile
    )
    # -Validate equivalent: checks transport, host, service, port,
    # snapshot_path, SeServiceLogonRight, ApiKey presence (Profile B)
    throw "Not implemented"
}

function New-LMApiKey {
    # Generates a new GUID-based API key
    throw "Not implemented"
}

function Protect-LMApiKey {
    [CmdletBinding()]
    param(
        [string]$ApiKey,
        [string]$RegistryRoot = 'HKLM:\SOFTWARE\LegacyMCP'
    )
    # DPAPI-NG encryption via subprocess PowerShell
    throw "Not implemented"
}

function Get-LMApiKey {
    [CmdletBinding()]
    param([string]$RegistryRoot = 'HKLM:\SOFTWARE\LegacyMCP')
    # DPAPI-NG decryption via subprocess PowerShell
    throw "Not implemented"
}

Export-ModuleMember -Function *
