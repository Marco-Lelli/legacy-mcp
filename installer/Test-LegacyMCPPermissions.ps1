# Test-LegacyMCPPermissions.ps1
# LegacyMCP -- Minimum Permissions Test Suite
#
# PURPOSE:
#   Verifies that the LegacyMCP service account has the minimum required
#   permissions to run the collector and Live Mode against a Domain Controller.
#   Run as an interactive logon session of the service account to simulate
#   the Kerberos token the service will obtain at runtime.
#
# USAGE:
#   .\Test-LegacyMCPPermissions.ps1 -DCHostName dc.domain.local -Domain domain.local
#   .\Test-LegacyMCPPermissions.ps1 -DCHostName dc.domain.local -Domain domain.local -Tests "T18,T20,T22"
#
# PARAMETERS:
#   -DCHostName   FQDN of the target Domain Controller (mandatory)
#   -Domain       DNS domain name, e.g. domain.local (mandatory)
#   -DomainDN     Distinguished name, e.g. DC=domain,DC=local (optional, derived if omitted)
#   -Tests        Comma-separated list of test IDs to run, e.g. "T01,T10,T18"
#                 Default: "all" -- runs all 22 tests
#
# AUTHENTICATION NOTE:
#   This script must be run on a domain-joined machine logged in interactively
#   as the service account. All remote connections use Kerberos (no NTLM fallback).
#
# OUTPUT:
#   - Console: color-coded PASS/FAIL/WARN/SKIP per test
#   - File:    test-report-<timestamp>.txt in the same folder
#
# REQUIREMENTS:
#   - RSAT ActiveDirectory module (for LDAP tests T01-T11)
#   - RSAT GroupPolicy module (for GPO tests T12-T13)
#   - RSAT DnsServer module (for DNS tests T14-T15)
#   - Network connectivity to the target DC
#   - Domain account with minimum LegacyMCP permissions granted

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$DCHostName,

    [Parameter(Mandatory=$true)]
    [string]$Domain,

    [string]$DomainDN = "",

    [string]$Tests = "all"
)

# Derive DomainDN from Domain if not provided
if (-not $DomainDN) {
    $DomainDN = "DC=" + $Domain.Replace(".", ",DC=")
}

# Parse test filter
$RunAll = ($Tests.Trim().ToLower() -eq "all")
$TestList = @()
if (-not $RunAll) {
    $TestList = $Tests.Split(",") | ForEach-Object { $_.Trim() }
}

function Should-Run {
    param([string]$Id)
    if ($RunAll) { return $true }
    return ($TestList -contains $Id)
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Timestamp  = Get-Date -Format "yyyyMMdd-HHmmss"
$ReportPath = Join-Path $PSScriptRoot "test-report-$Timestamp.txt"
$Results    = [System.Collections.Generic.List[PSCustomObject]]::new()

function Write-Result {
    param(
        [string]$TestId,
        [string]$Description,
        [ValidateSet("PASS","FAIL","WARN","SKIP")]
        [string]$Status,
        [string]$Detail = ""
    )
    $color = switch ($Status) {
        "PASS" { "Green"  }
        "FAIL" { "Red"    }
        "WARN" { "Yellow" }
        "SKIP" { "Cyan"   }
    }
    $line = "[$Status] $TestId - $Description"
    if ($Detail) { $line += ": $Detail" }
    Write-Host $line -ForegroundColor $color
    $Results.Add([PSCustomObject]@{
        TestId      = $TestId
        Description = $Description
        Status      = $Status
        Detail      = $Detail
        Timestamp   = (Get-Date -Format "HH:mm:ss")
    })
}

$CommonParams = @{ Server = $DCHostName }

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " LegacyMCP - Minimum Permissions Tests  " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Account : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host " DC      : $DCHostName"
Write-Host " Domain  : $Domain"
Write-Host " Started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

# ---------------------------------------------------------------------------
# FAMILY 1 -- LDAP
# ---------------------------------------------------------------------------

Write-Host "--- FAMILY 1: LDAP ---" -ForegroundColor White

if (Should-Run "T01") {
    try {
        $null = Get-ADDomain @CommonParams
        Write-Result "T01" "Basic AD connectivity (Get-ADDomain)" "PASS"
    } catch {
        Write-Result "T01" "Basic AD connectivity (Get-ADDomain)" "FAIL" $_.Exception.Message
    }
}

if (Should-Run "T02") {
    try {
        $dcs = Get-ADDomainController -Filter * @CommonParams
        Write-Result "T02" "DC enumeration (Get-ADDomainController)" "PASS" "$($dcs.Count) DC(s) found"
    } catch {
        Write-Result "T02" "DC enumeration (Get-ADDomainController)" "FAIL" $_.Exception.Message
    }
}

if (Should-Run "T03") {
    try {
        $users = @(Get-ADUser -Filter * -Properties adminCount, SIDHistory @CommonParams)
        $withAdminCount = @($users | Where-Object { $_.adminCount -eq 1 }).Count
        $withSIDHistory = @($users | Where-Object { $_.SIDHistory.Count -gt 0 }).Count
        Write-Result "T03" "Users with adminCount + SIDHistory" "PASS" `
            "$($users.Count) users, $withAdminCount with adminCount=1, $withSIDHistory with SIDHistory"
    } catch {
        Write-Result "T03" "Users with adminCount + SIDHistory" "FAIL" $_.Exception.Message
    }
}

if (Should-Run "T04") {
    try {
        $groups = Get-ADGroup -Filter * -Properties Members, adminCount @CommonParams
        Write-Result "T04" "Groups (Get-ADGroup)" "PASS" "$($groups.Count) groups found"
    } catch {
        Write-Result "T04" "Groups (Get-ADGroup)" "FAIL" $_.Exception.Message
    }
}

if (Should-Run "T05") {
    try {
        $computers = Get-ADComputer -Filter * -Properties OperatingSystem @CommonParams
        Write-Result "T05" "Computers (Get-ADComputer)" "PASS" "$($computers.Count) computers found"
    } catch {
        Write-Result "T05" "Computers (Get-ADComputer)" "FAIL" $_.Exception.Message
    }
}

if (Should-Run "T06") {
    try {
        $sites = Get-ADReplicationSite -Filter * @CommonParams
        Write-Result "T06" "Sites (Get-ADReplicationSite)" "PASS" "$($sites.Count) site(s) found"
    } catch {
        Write-Result "T06" "Sites (Get-ADReplicationSite)" "FAIL" $_.Exception.Message
    }
}

if (Should-Run "T07") {
    try {
        $trusts = @(Get-ADTrust -Filter * @CommonParams)
        Write-Result "T07" "Trusts (Get-ADTrust)" "PASS" "$($trusts.Count) trust(s) found"
    } catch {
        Write-Result "T07" "Trusts (Get-ADTrust)" "FAIL" $_.Exception.Message
    }
}

if (Should-Run "T08") {
    try {
        $schemaDN = (Get-ADRootDSE @CommonParams).schemaNamingContext
        $objs = Get-ADObject -SearchBase $schemaDN -Filter { adminDescription -like "*" } @CommonParams
        Write-Result "T08" "Schema (Get-ADObject on schemaNamingContext)" "PASS" "$($objs.Count) custom object(s)"
    } catch {
        Write-Result "T08" "Schema (Get-ADObject on schemaNamingContext)" "FAIL" $_.Exception.Message
    }
}

if (Should-Run "T09") {
    try {
        $null = Get-ADDefaultDomainPasswordPolicy @CommonParams
        Write-Result "T09" "Default Password Policy" "PASS"
    } catch {
        Write-Result "T09" "Default Password Policy" "FAIL" $_.Exception.Message
    }
}

if (Should-Run "T10") {
    try {
        $fgpp = @(Get-ADFineGrainedPasswordPolicy -Filter * @CommonParams)
        if ($fgpp.Count -eq 0) {
            Write-Result "T10" "FGPP (Get-ADFineGrainedPasswordPolicy)" "WARN" `
                "No FGPP objects found -- may not be configured, or access denied silently"
        } else {
            Write-Result "T10" "FGPP (Get-ADFineGrainedPasswordPolicy)" "PASS" "$($fgpp.Count) PSO(s) found"
        }
    } catch {
        Write-Result "T10" "FGPP (Get-ADFineGrainedPasswordPolicy)" "FAIL" $_.Exception.Message
    }
}

if (Should-Run "T11") {
    try {
        $configDN     = (Get-ADRootDSE @CommonParams).configurationNamingContext
        $enrollmentDN = "CN=Enrollment Services,CN=Public Key Services,CN=Services,$configDN"
        $pki = Get-ADObject -SearchBase $enrollmentDN -Filter * @CommonParams -ErrorAction Stop
        Write-Result "T11" "PKI - Configuration Partition (Get-ADObject)" "PASS" "$($pki.Count) CA object(s) found"
    } catch {
        if ($_.Exception.Message -match "not found|cannot find|00002095") {
            Write-Result "T11" "PKI - Configuration Partition (Get-ADObject)" "WARN" `
                "Enrollment Services container not found -- PKI may not be installed"
        } else {
            Write-Result "T11" "PKI - Configuration Partition (Get-ADObject)" "FAIL" $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------------
# FAMILY 2 -- RPC / RSAT
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "--- FAMILY 2: RPC / RSAT ---" -ForegroundColor White

if (Should-Run "T12") {
    if (Get-Module -ListAvailable -Name GroupPolicy) {
        try {
            $gpos = Get-GPO -All -Domain $Domain -Server $DCHostName
            Write-Result "T12" "GPO enumeration (Get-GPO)" "PASS" "$($gpos.Count) GPO(s) found"
        } catch {
            Write-Result "T12" "GPO enumeration (Get-GPO)" "FAIL" $_.Exception.Message
        }
    } else {
        Write-Result "T12" "GPO enumeration (Get-GPO)" "SKIP" "GroupPolicy RSAT module not installed"
    }
}

if (Should-Run "T13") {
    if (Get-Module -ListAvailable -Name GroupPolicy) {
        try {
            $null = Get-GPInheritance -Target $DomainDN -Domain $Domain -Server $DCHostName
            Write-Result "T13" "GPO inheritance (Get-GPInheritance)" "PASS"
        } catch {
            Write-Result "T13" "GPO inheritance (Get-GPInheritance)" "FAIL" $_.Exception.Message
        }
    } else {
        Write-Result "T13" "GPO inheritance (Get-GPInheritance)" "SKIP" "GroupPolicy RSAT module not installed"
    }
}

if (Should-Run "T14") {
    if (Get-Module -ListAvailable -Name DnsServer) {
        try {
            $zones = Get-DnsServerZone -ComputerName $DCHostName
            Write-Result "T14" "DNS zones (Get-DnsServerZone)" "PASS" "$($zones.Count) zone(s) found"
        } catch {
            Write-Result "T14" "DNS zones (Get-DnsServerZone)" "FAIL" $_.Exception.Message
        }
    } else {
        Write-Result "T14" "DNS zones (Get-DnsServerZone)" "SKIP" "DnsServer RSAT module not installed"
    }
}

if (Should-Run "T15") {
    if (Get-Module -ListAvailable -Name DnsServer) {
        try {
            $null = Get-DnsServerForwarder -ComputerName $DCHostName
            Write-Result "T15" "DNS forwarders (Get-DnsServerForwarder)" "PASS"
        } catch {
            Write-Result "T15" "DNS forwarders (Get-DnsServerForwarder)" "FAIL" $_.Exception.Message
        }
    } else {
        Write-Result "T15" "DNS forwarders (Get-DnsServerForwarder)" "SKIP" "DnsServer RSAT module not installed"
    }
}

# ---------------------------------------------------------------------------
# FAMILY 3 -- Remote DC access
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "--- FAMILY 3: Remote DC access ---" -ForegroundColor White

if (Should-Run "T16") {
    try {
        $result = Invoke-Command -ComputerName $DCHostName -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
        Write-Result "T16" "WinRM connectivity (Invoke-Command)" "PASS" "Connected to $result"
    } catch {
        Write-Result "T16" "WinRM connectivity (Invoke-Command)" "FAIL" $_.Exception.Message
    }
}

if (Should-Run "T17") {
    try {
        $features = Invoke-Command -ComputerName $DCHostName -ScriptBlock {
            Import-Module ServerManager -ErrorAction SilentlyContinue
            Get-WindowsFeature | Where-Object { $_.InstallState -eq 'Installed' -and $_.FeatureType -eq 'Role' }
        } -ErrorAction Stop
        Write-Result "T17" "Windows Features via WinRM (Get-WindowsFeature)" "PASS" "$($features.Count) installed role(s)"
    } catch {
        Write-Result "T17" "Windows Features via WinRM (Get-WindowsFeature)" "FAIL" $_.Exception.Message
    }
}

if (Should-Run "T18") {
    try {
        # CimSession with WSMan: forces Get-CimInstance over WinRM, not DCOM.
        # Remote Management Users is sufficient -- no Distributed COM Users needed.
        $cimOpt     = New-CimSessionOption -Protocol WSMan
        $cimSession = New-CimSession -ComputerName $DCHostName -SessionOption $cimOpt -ErrorAction Stop
        try {
            $services = Get-CimInstance -CimSession $cimSession -ClassName Win32_Service |
                Where-Object { $_.State -eq 'Running' }
        } finally {
            Remove-CimSession $cimSession
        }
        Write-Result "T18" "Services via WinRM (CimSession WSMan)" "PASS" "$($services.Count) running service(s)"
    } catch {
        $statusValue = if ($_.Exception.Message -match "Access is denied|Access denied|0x80070005") {
            "PermissionDenied"
        } else {
            "Unreachable"
        }
        Write-Result "T18" "Services via WinRM (CimSession WSMan)" "FAIL" "Status: $statusValue -- $($_.Exception.Message)"
    }
}

if (Should-Run "T19") {
    try {
        $sw = Invoke-Command -ComputerName $DCHostName -ScriptBlock {
            Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
        } -ErrorAction Stop
        Write-Result "T19" "Installed software via WinRM (registry)" "PASS" "$($sw.Count) package(s) found"
    } catch {
        Write-Result "T19" "Installed software via WinRM (registry)" "FAIL" $_.Exception.Message
    }
}

if (Should-Run "T20") {
    try {
        # "Security" log excluded: requires Administrators, not delegable granularly.
        $logs = Get-WinEvent -ListLog "Application", "System" `
            -ComputerName $DCHostName -ErrorAction Stop
        Write-Result "T20" "EventLog remote (Get-WinEvent - Application + System only)" "PASS" "$($logs.Count) log(s) accessible"
    } catch {
        Write-Result "T20" "EventLog remote (Get-WinEvent - Application + System only)" "FAIL" $_.Exception.Message
    }
}

if (Should-Run "T21") {
    try {
        $SysvolStateMap = @{ 0="Uninitialized"; 1="Initialized"; 2="Initial Sync";
                             3="Auto Recovery"; 4="Normal"; 5="In Error" }
        $dfsr = @(Get-WmiObject -Namespace "root\MicrosoftDFS" `
            -Class DfsrReplicatedFolderInfo `
            -ComputerName $DCHostName `
            -Filter "ReplicatedFolderName='SYSVOL Share'" `
            -ErrorAction Stop)

        if ($dfsr.Count -gt 0) {
            # DFSR active
            $stateInt = [int]$dfsr[0].State
            $stateStr = if ($SysvolStateMap.ContainsKey($stateInt)) {
                $SysvolStateMap[$stateInt]
            } else { "Unknown ($stateInt)" }
            Write-Result "T21" "SYSVOL replication (DFSR)" "PASS" "Mechanism: DFSR, State: $stateStr"
        } else {
            # Step 2a: LDAP check for DFSR-GlobalSettings (domain user, no extra permissions)
            # Wrapped in try/catch: SearchRoot assignment can throw DirectoryServicesCOMException
            # if the DN does not exist (FRS environment).
            try {
                $dfsrGlobalDN = "CN=DFSR-GlobalSettings,CN=System,$DomainDN"
                $searcher = New-Object DirectoryServices.DirectorySearcher
                $searcher.SearchRoot = New-Object DirectoryServices.DirectoryEntry(
                    "LDAP://$DCHostName/$dfsrGlobalDN")
                $searcher.SearchScope = "Base"
                $dfsrGlobal = $searcher.FindOne()
            } catch [System.Runtime.InteropServices.COMException] {
                # CN=DFSR-GlobalSettings does not exist -> FRS environment
                $dfsrGlobal = $null
            } catch {
                # Any other LDAP error -> treat as FRS, log error
                $dfsrGlobal = $null
            }

            if ($dfsrGlobal) {
                Write-Result "T21" "SYSVOL replication (DFSR)" "PASS" `
                    "Mechanism: DFSR, replicated folders not yet configured on this DC"
            } else {
                # Step 2b: confirm NtFrs via registry Invoke-Command
                # (Remote Management Users already granted)
                $ntfrs = Invoke-Command -ComputerName $DCHostName -ScriptBlock {
                    $svc = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NtFrs" `
                        -ErrorAction SilentlyContinue
                    [PSCustomObject]@{
                        ServiceFound = [bool]$svc
                        Start        = if ($svc) { $svc.Start } else { $null }
                    }
                } -ErrorAction SilentlyContinue

                if ($ntfrs -and $ntfrs.ServiceFound) {
                    Write-Result "T21" "SYSVOL replication (FRS)" "WARN" `
                        "Mechanism: FRS (pre-migration) -- DFSR state not available"
                } else {
                    Write-Result "T21" "SYSVOL replication (Unknown)" "WARN" `
                        "Neither DFSR folders nor NtFrs service detected"
                }
            }
        }
    } catch {
        Write-Result "T21" "SYSVOL replication" "FAIL" $_.Exception.Message
    }
}

if (Should-Run "T22") {
    try {
        $ntpServer = Invoke-Command -ComputerName $DCHostName -ScriptBlock {
            (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters" `
                -ErrorAction SilentlyContinue).NtpServer
        } -ErrorAction Stop
        Write-Result "T22" "NTP config via WinRM (Invoke-Command)" "PASS" "NtpServer: $ntpServer"
    } catch {
        Write-Result "T22" "NTP config via WinRM (Invoke-Command)" "FAIL" $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$pass = @($Results | Where-Object Status -eq "PASS").Count
$fail = @($Results | Where-Object Status -eq "FAIL").Count
$warn = @($Results | Where-Object Status -eq "WARN").Count
$skip = @($Results | Where-Object Status -eq "SKIP").Count

Write-Host " PASS : $pass" -ForegroundColor Green
Write-Host " FAIL : $fail" -ForegroundColor Red
Write-Host " WARN : $warn" -ForegroundColor Yellow
Write-Host " SKIP : $skip" -ForegroundColor Cyan
Write-Host ""

if ($fail -gt 0) {
    Write-Host " Failed tests:" -ForegroundColor Red
    $Results | Where-Object Status -eq "FAIL" | ForEach-Object {
        Write-Host "   $($_.TestId) - $($_.Description)" -ForegroundColor Red
        if ($_.Detail) { Write-Host "         $($_.Detail)" -ForegroundColor DarkRed }
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Write report file
# ---------------------------------------------------------------------------

$reportLines = @(
    "LegacyMCP - Minimum Permissions Test Report",
    "============================================",
    "Account  : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)",
    "DC       : $DCHostName",
    "Domain   : $Domain",
    "Date     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "",
    "Results",
    "-------"
)

foreach ($r in $Results) {
    $reportLines += "[$($r.Status)] $($r.TestId) - $($r.Description)"
    if ($r.Detail) { $reportLines += "       Detail: $($r.Detail)" }
}

$reportLines += ""
$reportLines += "Summary"
$reportLines += "-------"
$reportLines += "PASS : $pass"
$reportLines += "FAIL : $fail"
$reportLines += "WARN : $warn"
$reportLines += "SKIP : $skip"

[System.IO.File]::WriteAllLines(
    $ReportPath,
    $reportLines,
    [System.Text.UTF8Encoding]::new($false)
)
Write-Host " Report saved to: $ReportPath" -ForegroundColor Cyan
Write-Host ""
