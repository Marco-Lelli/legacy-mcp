# Remove-LegacyMCPPermissions.ps1
# LegacyMCP -- Service Account Permission Revocation
#
# PURPOSE:
#   Revokes all POLP delegations previously applied by Set-LegacyMCPPermissions.ps1.
#   Speculare (inverse) to Set-LegacyMCPPermissions.ps1 -- same structure,
#   same prerequisites, same 7 operations in reverse.
#
#   If the current user IS a member of Domain Admins, all delegations are
#   revoked automatically and results are reported per operation.
#
#   If the current user is NOT a member of Domain Admins, the script prints
#   a formatted table of all delegations to revoke for manual removal
#   and exits with code 2. No changes are made.
#
# WARNING:
#   This script removes delegations from the service account. After execution,
#   the account will no longer be able to run LegacyMCP in Live Mode.
#   Ensure the service is stopped before running this script.
#
# USAGE:
#   .\Remove-LegacyMCPPermissions.ps1 -ServiceAccountName svc_legacymcp `
#       -Domain house.local -DCHostName PUPP.house.local
#
# PARAMETERS:
#   -ServiceAccountName   SAM account name of the service account (e.g. svc_legacymcp)
#   -Domain               DNS domain name (e.g. house.local)
#   -DCHostName           FQDN of the primary DC (e.g. PUPP.house.local).
#                         AD revocations (groups, LDAP ACLs) replicate automatically
#                         to all DCs in the forest.
#                         WMI revocations are applied individually to every DC.
#
# OPERATIONS PERFORMED:
#   1. Remote Management Users (Domain Local group) -- removed
#   2. Event Log Readers (Domain Local group) -- removed
#   3. WMI root\MicrosoftDFS -- ACE removed on every DC in the forest
#   4. CN=Password Settings Container,CN=System,<DomainDN> -- GenericRead revoked
#   5. CN=MicrosoftDNS,DC=DomainDnsZones,<DomainDN> -- GenericRead revoked
#   6. CN=MicrosoftDNS,DC=ForestDnsZones,<DomainDN> -- GenericRead revoked
#   7. CN=MicrosoftDNS,CN=System,<DomainDN> -- GenericRead revoked
#
# IDEMPOTENCE:
#   Each operation checks current state before acting. Safe to run multiple times.
#
# EXIT CODES:
#   0 -- All delegations removed or already absent
#   1 -- One or more operations failed (or prerequisite error)
#   2 -- Not a Domain Admin: no changes made, manual revocation table printed
#
# REQUIREMENTS:
#   - PowerShell 5.1 or later
#   - RSAT ActiveDirectory module (Add-WindowsFeature RSAT-AD-PowerShell)
#   - Domain Admin membership (or see exit code 2 behavior above)
#   - Network connectivity to DCHostName
#   - Kerberos authentication -- NTLM is not supported

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ServiceAccountName,

    [Parameter(Mandatory=$true)]
    [string]$Domain,

    [Parameter(Mandatory=$true)]
    [string]$DCHostName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Derived variables
$DomainDN   = "DC=" + $Domain.Replace(".", ",DC=")
$SAMAccount = "$Domain\$ServiceAccountName"

# Counters
$removed       = 0
$alreadyAbsent = 0
$failed        = 0

# ---------------------------------------------------------------------------
# Helper: Write-Action
# ---------------------------------------------------------------------------

function Write-Action {
    param(
        [ValidateSet("REMOVED","OK","FAIL")]
        [string]$Status,
        [string]$Target,
        [string]$Detail = ""
    )
    $color = switch ($Status) {
        "REMOVED" { "Cyan"  }
        "OK"      { "Green" }
        "FAIL"    { "Red"   }
    }
    $tag  = "[$Status]".PadRight(10)
    $line = "$tag $Target"
    if ($Detail) { $line += " -- $Detail" }
    Write-Host $line -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host " LegacyMCP -- Remove Service Account Permissions" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host " Account : $SAMAccount"
Write-Host " DC      : $DCHostName"
Write-Host " Domain  : $Domain"
Write-Host " Started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""
Write-Host " WARNING: this script revokes delegations. The account will no" -ForegroundColor Yellow
Write-Host "          longer be able to run LegacyMCP in Live Mode." -ForegroundColor Yellow
Write-Host ""

# ---------------------------------------------------------------------------
# PREREQUISITES
# ---------------------------------------------------------------------------

Write-Host "--- Prerequisites ---" -ForegroundColor White

# 1. ActiveDirectory module
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Host "[OK]    ActiveDirectory module loaded" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] ActiveDirectory module not available: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "        Install with: Add-WindowsFeature RSAT-AD-PowerShell" -ForegroundColor Yellow
    exit 1
}

# 2. DC reachable (Kerberos -- P3)
try {
    $null = Invoke-Command -ComputerName $DCHostName -Authentication Kerberos `
        -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
    Write-Host "[OK]    DC reachable: $DCHostName" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] DC not reachable ($DCHostName): $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# 3. Service account exists
try {
    $adAccount = Get-ADUser -Identity $ServiceAccountName -Server $DCHostName -ErrorAction Stop
    Write-Host "[OK]    Service account found: $($adAccount.DistinguishedName)" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Service account '$ServiceAccountName' not found in $Domain" -ForegroundColor Red
    exit 1
}

# 4. Domain Admin rights check
#    Domain Admin  -> proceed with automated revocation
#    Not Domain Admin -> print manual-revocation table and exit 2 (no changes made)
try {
    $daGroup      = Get-ADGroup "Domain Admins" -Server $DCHostName -ErrorAction Stop
    $daSid        = [System.Security.Principal.SecurityIdentifier]$daGroup.SID
    $identity     = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal    = New-Object System.Security.Principal.WindowsPrincipal($identity)
    $isDomainAdmin = $principal.IsInRole($daSid)
} catch {
    Write-Host "[ERROR] Cannot determine Domain Admins membership: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if (-not $isDomainAdmin) {
    Write-Host ""
    Write-Host " Current account is not a member of Domain Admins." -ForegroundColor Yellow
    Write-Host " No changes have been made." -ForegroundColor Yellow
    Write-Host " Revoke the following delegations manually for: $SAMAccount" -ForegroundColor Yellow
    Write-Host ""

    $manualRows = @(
        [PSCustomObject]@{
            Category = "AD Group"
            Object   = "Remote Management Users"
            Action   = "Remove member"
        }
        [PSCustomObject]@{
            Category = "AD Group"
            Object   = "Event Log Readers"
            Action   = "Remove member"
        }
        [PSCustomObject]@{
            Category = "WMI Namespace"
            Object   = "root\MicrosoftDFS (each DC)"
            Action   = "Remove ACE"
        }
        [PSCustomObject]@{
            Category = "AD ACL (LDAP)"
            Object   = "CN=Password Settings Container,CN=System,$DomainDN"
            Action   = "Revoke GenericRead"
        }
        [PSCustomObject]@{
            Category = "AD ACL (LDAP)"
            Object   = "CN=MicrosoftDNS,DC=DomainDnsZones,$DomainDN"
            Action   = "Revoke GenericRead"
        }
        [PSCustomObject]@{
            Category = "AD ACL (LDAP)"
            Object   = "CN=MicrosoftDNS,DC=ForestDnsZones,$DomainDN"
            Action   = "Revoke GenericRead"
        }
        [PSCustomObject]@{
            Category = "AD ACL (LDAP)"
            Object   = "CN=MicrosoftDNS,CN=System,$DomainDN"
            Action   = "Revoke GenericRead"
        }
    )

    $manualRows | Format-Table -AutoSize | Out-String | Write-Host
    exit 2
}

Write-Host "[OK]    Running as Domain Admin: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------------
# OPERATIONS
# ---------------------------------------------------------------------------

Write-Host "--- Operations ---" -ForegroundColor White

# ---------------------------------------------------------------------------
# 1. Remote Management Users
# ---------------------------------------------------------------------------

try {
    $rmMembers  = Get-ADGroupMember -Identity "Remote Management Users" -Server $DCHostName -ErrorAction Stop
    $isRmMember = @($rmMembers | Where-Object { $_.SID -eq $adAccount.SID }).Count -gt 0

    if ($isRmMember) {
        Remove-ADGroupMember -Identity "Remote Management Users" -Members $ServiceAccountName `
            -Server $DCHostName -Confirm:$false -ErrorAction Stop
        Write-Action "REMOVED" "Remote Management Users" "$ServiceAccountName removed"
        $removed++
    } else {
        Write-Action "OK" "Remote Management Users" "$ServiceAccountName already absent"
        $alreadyAbsent++
    }
} catch {
    Write-Action "FAIL" "Remote Management Users" $_.Exception.Message
    $failed++
}

# ---------------------------------------------------------------------------
# 2. Event Log Readers
# ---------------------------------------------------------------------------

try {
    $elMembers  = Get-ADGroupMember -Identity "Event Log Readers" -Server $DCHostName -ErrorAction Stop
    $isElMember = @($elMembers | Where-Object { $_.SID -eq $adAccount.SID }).Count -gt 0

    if ($isElMember) {
        Remove-ADGroupMember -Identity "Event Log Readers" -Members $ServiceAccountName `
            -Server $DCHostName -Confirm:$false -ErrorAction Stop
        Write-Action "REMOVED" "Event Log Readers" "$ServiceAccountName removed"
        $removed++
    } else {
        Write-Action "OK" "Event Log Readers" "$ServiceAccountName already absent"
        $alreadyAbsent++
    }
} catch {
    Write-Action "FAIL" "Event Log Readers" $_.Exception.Message
    $failed++
}

# ---------------------------------------------------------------------------
# 3. WMI namespace root\MicrosoftDFS -- removed on every DC (P10: soft degradation)
#    Loop uses explicit counter to find ACE index -- avoids IndexOf with StrictMode.
# ---------------------------------------------------------------------------

$accountSid = $adAccount.SID.Value

$wmiRemoveScriptBlock = {
    param($AccountSid)

    $ErrorActionPreference = "Stop"
    $namespace = "root\MicrosoftDFS"

    $getResult = Invoke-WmiMethod -Namespace $namespace -Class "__SystemSecurity" -Name "GetSD"
    if ($getResult.ReturnValue -ne 0) {
        throw "GetSD failed: $($getResult.ReturnValue)"
    }

    $rawSD = New-Object System.Security.AccessControl.RawSecurityDescriptor($getResult.SD, 0)
    $sid   = New-Object System.Security.Principal.SecurityIdentifier($AccountSid)

    $aceIndex = -1
    for ($i = 0; $i -lt $rawSD.DiscretionaryAcl.Count; $i++) {
        $ace = $rawSD.DiscretionaryAcl[$i]
        if ($ace -is [System.Security.AccessControl.CommonAce] -and
            $ace.SecurityIdentifier -eq $sid) {
            $aceIndex = $i
            break
        }
    }

    if ($aceIndex -eq -1) {
        return "already_absent"
    }

    $rawSD.DiscretionaryAcl.RemoveAce($aceIndex)

    $binarySD = New-Object byte[] $rawSD.BinaryLength
    $rawSD.GetBinaryForm($binarySD, 0)

    $setResult = Invoke-WmiMethod -Namespace $namespace -Class "__SystemSecurity" -Name "SetSD" -ArgumentList @(,$binarySD)
    if ($setResult.ReturnValue -ne 0) {
        throw "SetSD failed: $($setResult.ReturnValue)"
    }

    return "removed"
}

$allDCs = $null
try {
    $allDCs = Get-ADDomainController -Filter * -Server $DCHostName -ErrorAction Stop
} catch {
    Write-Action "FAIL" "WMI root\MicrosoftDFS" "Cannot enumerate DCs: $($_.Exception.Message)"
    $failed++
}

if ($allDCs) {
    foreach ($dc in $allDCs) {
        $dcFqdn = $dc.HostName
        try {
            $wmiResult = Invoke-Command -ComputerName $dcFqdn -Authentication Kerberos `
                -ArgumentList $accountSid `
                -ScriptBlock $wmiRemoveScriptBlock -ErrorAction Stop

            if ($wmiResult -eq "already_absent") {
                Write-Action "OK"      "WMI root\MicrosoftDFS" "ACE already absent on $dcFqdn"
                $alreadyAbsent++
            } else {
                Write-Action "REMOVED" "WMI root\MicrosoftDFS" "ACE removed on $dcFqdn"
                $removed++
            }
        } catch {
            Write-Action "FAIL" "WMI root\MicrosoftDFS" "Error on $dcFqdn -- $($_.Exception.Message)"
            $failed++
        }
    }
}

# ---------------------------------------------------------------------------
# Helper: Remove-AdAclIfPresent
#   Checks whether the service account has any explicit ACE on a given AD object.
#   Revokes all explicit permissions via dsacls /R only if an ACE is found.
#   Updates script-scope counters directly.
#   If SID translation fails on an ACE, that ACE is skipped -- only an explicit
#   SID match triggers revocation. This avoids acting on ACEs that cannot be
#   identified (fail-safe: do not remove what cannot be confirmed as ours).
# ---------------------------------------------------------------------------

function Remove-AdAclIfPresent {
    param(
        [string]$TargetDN,
        [string]$DisplayName,
        [string]$AccountSAM,
        [System.Security.Principal.SecurityIdentifier]$AccountSID
    )
    try {
        $acl    = Get-Acl "AD:\$TargetDN" -ErrorAction Stop
        $sidVal = $AccountSID.Value
        $hasAce = $false
        foreach ($entry in $acl.Access) {
            try {
                $entrySid = $entry.IdentityReference.Translate(
                    [System.Security.Principal.SecurityIdentifier]).Value
                if ($entrySid -eq $sidVal) {
                    $hasAce = $true
                    break
                }
            } catch {
                # SID translation failed for this ACE: skip it, cannot confirm it is ours.
                continue
            }
        }

        if ($hasAce) {
            $output = & dsacls $TargetDN /R $AccountSAM 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "dsacls /R failed (exit $LASTEXITCODE): $($output -join ' ')"
            }
            Write-Action "REMOVED" $DisplayName "ACE revoked"
            $script:removed++
        } else {
            Write-Action "OK" $DisplayName "already absent"
            $script:alreadyAbsent++
        }
    } catch {
        Write-Action "FAIL" $DisplayName $_.Exception.Message
        $script:failed++
    }
}

# ---------------------------------------------------------------------------
# 4. CN=Password Settings Container -- revoke GenericRead
# ---------------------------------------------------------------------------

Remove-AdAclIfPresent `
    -TargetDN   "CN=Password Settings Container,CN=System,$DomainDN" `
    -DisplayName "CN=Password Settings Container" `
    -AccountSAM  $SAMAccount `
    -AccountSID  $adAccount.SID

# ---------------------------------------------------------------------------
# 5. CN=MicrosoftDNS,DC=DomainDnsZones -- revoke GenericRead
# ---------------------------------------------------------------------------

Remove-AdAclIfPresent `
    -TargetDN    "CN=MicrosoftDNS,DC=DomainDnsZones,$DomainDN" `
    -DisplayName "CN=MicrosoftDNS DomainDnsZones" `
    -AccountSAM  $SAMAccount `
    -AccountSID  $adAccount.SID

# ---------------------------------------------------------------------------
# 6. CN=MicrosoftDNS,DC=ForestDnsZones -- revoke GenericRead
# ---------------------------------------------------------------------------

Remove-AdAclIfPresent `
    -TargetDN    "CN=MicrosoftDNS,DC=ForestDnsZones,$DomainDN" `
    -DisplayName "CN=MicrosoftDNS ForestDnsZones" `
    -AccountSAM  $SAMAccount `
    -AccountSID  $adAccount.SID

# ---------------------------------------------------------------------------
# 7. CN=MicrosoftDNS,CN=System -- revoke GenericRead
# ---------------------------------------------------------------------------

Remove-AdAclIfPresent `
    -TargetDN    "CN=MicrosoftDNS,CN=System,$DomainDN" `
    -DisplayName "CN=MicrosoftDNS System (DNS RPC)" `
    -AccountSAM  $SAMAccount `
    -AccountSID  $adAccount.SID

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host " SUMMARY" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

$failColor = if ($failed -gt 0) { "Red" } else { "Green" }
Write-Host " Removed       : $removed"       -ForegroundColor Cyan
Write-Host " Already absent: $alreadyAbsent" -ForegroundColor Green
Write-Host " Failed        : $failed"        -ForegroundColor $failColor
Write-Host ""
Write-Host "Remove-LegacyMCPPermissions completed: $removed removed, $alreadyAbsent already absent, $failed failed"
Write-Host ""

if ($failed -gt 0) { exit 1 } else { exit 0 }
