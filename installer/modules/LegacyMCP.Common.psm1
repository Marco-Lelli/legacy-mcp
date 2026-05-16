# LegacyMCP.Common.psm1
# Shared utilities: structured output, registry read/write, elevation check.
# Used by all other LegacyMCP modules.

function Write-LMStep { param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor White }

function Write-LMOK   { param([string]$Message)
    Write-Host "  [OK]   $Message" -ForegroundColor Green }

function Write-LMFail { param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red }

function Write-LMWarn { param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow }

function Write-LMInfo { param([string]$Message)
    Write-Host "  [INFO] $Message" -ForegroundColor Cyan }

function Test-LMElevation {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-LMElevation {
    param([string]$Context = 'This operation')
    if (-not (Test-LMElevation)) {
        throw "$Context requires Administrator privileges. Re-run as Administrator."
    }
}

function Get-LMRegistry {
    [CmdletBinding()]
    param(
        [string]$Key  = 'HKLM:\SOFTWARE\LegacyMCP',
        [string]$Name
    )
    try {
        if ([string]::IsNullOrEmpty($Name)) {
            $props = Get-ItemProperty -Path $Key -ErrorAction Stop
            $ht = @{}
            $props.PSObject.Properties |
                Where-Object { $_.Name -notlike 'PS*' } |
                ForEach-Object { $ht[$_.Name] = $_.Value }
            return $ht
        } else {
            return Get-ItemPropertyValue -Path $Key -Name $Name -ErrorAction Stop
        }
    } catch {
        return $null
    }
}

function Set-LMRegistry {
    [CmdletBinding()]
    param(
        [string]$Key   = 'HKLM:\SOFTWARE\LegacyMCP',
        [string]$Name,
        [object]$Value,
        [string]$Type  = 'String'
    )
    try {
        if (-not (Test-Path $Key)) {
            New-Item -Path $Key -Force | Out-Null
        }
        Set-ItemProperty -Path $Key -Name $Name -Value $Value -Type $Type -ErrorAction Stop
    } catch {
        throw "Failed to write registry '$Key\$Name': $_"
    }
}

function Remove-LMRegistry {
    [CmdletBinding()]
    param([string]$Key = 'HKLM:\SOFTWARE\LegacyMCP')
    try {
        if (Test-Path $Key) {
            Remove-Item -Path $Key -Recurse -Force -ErrorAction Stop
        }
    } catch {
        throw "Failed to remove registry key '$Key': $_"
    }
}

Export-ModuleMember -Function *
