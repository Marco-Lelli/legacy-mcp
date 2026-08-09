# Logging.psm1 -- safe logging shim for collector modules.
#
# Why this exists
# ---------------
# Write-CollectorLog is defined at SCRIPT scope in Collect-ADData.ps1.
# A function inside a .psm1 resolves unqualified commands in its own module
# scope and then in the GLOBAL scope -- never in the script scope of the
# caller. The two invocation styles therefore behave differently:
#
#   powershell.exe -File Collect-ADData.ps1   -> script scope is effectively
#                                                global, modules DO see it
#   .\Collect-ADData.ps1 from an open session -> script scope is a child of
#                                                global, modules DO NOT see it
#
# Field-confirmed on AUSL Romagna (2026-08-06): the collector is always
# launched the second way, and a direct Write-CollectorLog call from inside
# Users.psm1 raised CommandNotFoundException, which escaped Get-UsersData and
# cost the ENTIRE Users section.
#
# Collect-ADData.ps1 now declares Write-CollectorLog as global, which is the
# actual fix -- warnings reach the log file and increment sections_warn under
# both invocation styles. This shim is the safety net behind it (P9): a module
# used standalone, or a host script that forgets the global declaration, must
# degrade to Write-Warning instead of throwing and losing a whole section.

function Write-SafeCollectorLog {
    [CmdletBinding()]
    param(
        [string]$Level   = "WARN",
        [string]$Section = "",
        [string]$Message
    )

    if (Get-Command Write-CollectorLog -ErrorAction SilentlyContinue) {
        Write-CollectorLog -Level $Level -Section $Section -Message $Message
        return
    }

    # Fallback: never throw from a logging call.
    $prefix = if ($Section) { "[$Level] $Section : " } else { "[$Level] " }
    switch ($Level) {
        "ERROR"   { Write-Error   ($prefix + $Message) -ErrorAction Continue }
        "VERBOSE" { Write-Verbose ($prefix + $Message) }
        default   { Write-Warning ($prefix + $Message) }
    }
}

Export-ModuleMember -Function Write-SafeCollectorLog
