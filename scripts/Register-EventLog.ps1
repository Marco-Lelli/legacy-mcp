#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers the LegacyMCP EventLog source on the local machine.
.DESCRIPTION
    Must be run once as Administrator before starting the LegacyMCP server.
    Safe to run multiple times (idempotent).
#>

$logName = "LegacyMCP"
$source  = "LegacyMCP"

try {
    if ([System.Diagnostics.EventLog]::SourceExists($source)) {
        Write-Host "[OK] EventLog source '$source' already registered." -ForegroundColor Green
    } else {
        New-EventLog -LogName $logName -Source $source
        Write-Host "[OK] EventLog source '$source' registered successfully." -ForegroundColor Green
    }
} catch {
    Write-Error "Failed to register EventLog source: $_"
    exit 1
}
