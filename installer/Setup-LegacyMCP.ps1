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

    [switch]$Gui
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesDir = Join-Path $ScriptDir 'modules'

# Import all LegacyMCP modules
Import-Module (Join-Path $ModulesDir 'LegacyMCP.Common.psm1')  -Force
Import-Module (Join-Path $ModulesDir 'LegacyMCP.Python.psm1')  -Force
Import-Module (Join-Path $ModulesDir 'LegacyMCP.Service.psm1') -Force
Import-Module (Join-Path $ModulesDir 'LegacyMCP.Certs.psm1')   -Force
Import-Module (Join-Path $ModulesDir 'LegacyMCP.Config.psm1')  -Force
Import-Module (Join-Path $ModulesDir 'LegacyMCP.Client.psm1')  -Force

if ($Gui) {
    throw "GUI mode is not yet implemented (Phase 5)."
}

throw "Setup-LegacyMCP.ps1 is not yet implemented. Use Install-LegacyMCP.ps1 for now."
