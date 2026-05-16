# LegacyMCP.Common.psm1
# Shared utilities: structured output, registry read/write, elevation check.
# Used by all other LegacyMCP modules.

function Write-LMStep   { [CmdletBinding()] param([string]$Message) throw "Not implemented" }
function Write-LMOK     { [CmdletBinding()] param([string]$Message) throw "Not implemented" }
function Write-LMFail   { [CmdletBinding()] param([string]$Message) throw "Not implemented" }
function Write-LMWarn   { [CmdletBinding()] param([string]$Message) throw "Not implemented" }
function Write-LMInfo   { [CmdletBinding()] param([string]$Message) throw "Not implemented" }

function Test-LMElevation {
    # Returns $true if running as Administrator
    throw "Not implemented"
}

function Assert-LMElevation {
    # Throws if not running as Administrator
    throw "Not implemented"
}

function Get-LMRegistry {
    [CmdletBinding()]
    param(
        [string]$Key,
        [string]$Name
    )
    throw "Not implemented"
}

function Set-LMRegistry {
    [CmdletBinding()]
    param(
        [string]$Key,
        [string]$Name,
        [object]$Value,
        [string]$Type = 'String'
    )
    throw "Not implemented"
}

function Remove-LMRegistry {
    [CmdletBinding()]
    param([string]$Key)
    throw "Not implemented"
}

Export-ModuleMember -Function *
