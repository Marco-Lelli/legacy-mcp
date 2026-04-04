#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers the LegacyMCP EventLog source on the local machine.
.DESCRIPTION
    Must be run once as Administrator before starting the LegacyMCP server.
    Safe to run multiple times (idempotent).

    Log name  : LegacyMCP        (dedicated Windows Event Log)
    Source    : LegacyMCP-Server (source name must differ from log name --
                Windows does not allow deleting a source whose name equals
                the log name, which would break Uninstall-LegacyMCP.ps1)
#>

$logName = "LegacyMCP"
$source  = "LegacyMCP-Server"

try {
    if ([System.Diagnostics.EventLog]::SourceExists($source)) {
        Write-Host "[OK] EventLog source '$source' already registered." -ForegroundColor Green
    } else {
        New-EventLog -LogName $logName -Source $source
        Write-Host "[OK] EventLog source '$source' registered in log '$logName'." -ForegroundColor Green
    }
} catch {
    Write-Error "Failed to register EventLog source: $_"
    exit 1
}
