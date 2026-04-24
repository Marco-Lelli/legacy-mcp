# Set-LegacyMCPPermissions.ps1
# LegacyMCP -- Service Account Permission Delegation
#
# PURPOSE:
#   Applies all POLP (Principle of Least Privilege) delegations required for a
#   service account to run LegacyMCP in Live Mode (Profile B-core).
#   The script does NOT create the service account -- this is an operational
#   prerequisite managed by the customer with their own naming conventions
#   and internal processes.
#
#   If the current user IS a member of Domain Admins, all delegations are
#   applied automatically and results are reported per delegation.
#
#   If the current user is NOT a member of Domain Admins, the script prints
#   a formatted table of all required delegations for manual assignment
#   and exits with code 2. No changes are made.
#
# USAGE:
#   .\Set-LegacyMCPPermissions.ps1 -ServiceAccountName svc_legacymcp `
#       -Domain house.local -DCHostName PUPP.house.local
#
# PARAMETERS:
#   -ServiceAccountName   SAM account name of the service account (e.g. svc_legacymcp)
#   -Domain               DNS domain name (e.g. house.local)
#   -DCHostName           FQDN of the primary DC (e.g. PUPP.house.local).
#                         AD delegations (groups, LDAP ACLs) replicate automatically
#                         to all DCs in the forest.
#                         WMI delegations are applied individually to every DC.
#
# DELEGATIONS APPLIED:
#   1. Remote Management Users (Domain Local group)
#      -- WinRM access, Get-WindowsFeature, Invoke-Command
#   2. Event Log Readers (Domain Local group)
#      -- Application + System log (Security log excluded: not delegable)
#   3. WMI root\MicrosoftDFS -- Execute Methods + Enable Account + Remote Enable
#      -- Applied on every DC in the forest via Invoke-Command (Kerberos)
#   4. CN=Password Settings Container,CN=System,<DomainDN>
#      -- GenericRead, InheritanceType All -- FGPP enumeration
#   5. CN=MicrosoftDNS,DC=DomainDnsZones,<DomainDN>
#      -- GenericRead -- DNS zones in domain partition
#   6. CN=MicrosoftDNS,DC=ForestDnsZones,<DomainDN>
#      -- GenericRead -- DNS zones in forest partition (includes _msdcs)
#
# IDEMPOTENCE:
#   Each delegation checks current state before applying. Safe to run multiple times.
#
# EXIT CODES:
#   0 -- All delegations applied or already present
#   1 -- One or more delegations failed (or prerequisite error)
#   2 -- Not a Domain Admin: no changes made, manual delegation table printed
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
$applied        = 0
$alreadyPresent = 0
$failed         = 0

# ---------------------------------------------------------------------------
# Helper: Write-Action
# ---------------------------------------------------------------------------

function Write-Action {
    param(
        [ValidateSet("OK","SET","FAIL")]
        [string]$Status,
        [string]$Target,
        [string]$Detail = ""
    )
    $color = switch ($Status) {
        "OK"   { "Green" }
        "SET"  { "Cyan"  }
        "FAIL" { "Red"   }
    }
    $tag  = "[$Status]".PadRight(7)
    $line = "$tag $Target"
    if ($Detail) { $line += " -- $Detail" }
    Write-Host $line -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " LegacyMCP -- Set Service Account Permissions" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Account : $SAMAccount"
Write-Host " DC      : $DCHostName"
Write-Host " Domain  : $Domain"
Write-Host " Started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
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
#    Domain Admin  -> proceed with automated delegation
#    Not Domain Admin -> print manual-assignment table and exit 2 (no changes made)
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
    Write-Host " Apply the following delegations manually for: $SAMAccount" -ForegroundColor Yellow
    Write-Host ""

    $manualRows = @(
        [PSCustomObject]@{
            Category = "AD Group"
            Object   = "Remote Management Users"
            Rights   = "Member"
        }
        [PSCustomObject]@{
            Category = "AD Group"
            Object   = "Event Log Readers"
            Rights   = "Member"
        }
        [PSCustomObject]@{
            Category = "WMI Namespace"
            Object   = "root\MicrosoftDFS (each DC)"
            Rights   = "Execute Methods, Enable Account, Remote Enable"
        }
        [PSCustomObject]@{
            Category = "AD ACL (LDAP)"
            Object   = "CN=Password Settings Container,CN=System,$DomainDN"
            Rights   = "GenericRead, InheritanceType All"
        }
        [PSCustomObject]@{
            Category = "AD ACL (LDAP)"
            Object   = "CN=MicrosoftDNS,DC=DomainDnsZones,$DomainDN"
            Rights   = "GenericRead"
        }
        [PSCustomObject]@{
            Category = "AD ACL (LDAP)"
            Object   = "CN=MicrosoftDNS,DC=ForestDnsZones,$DomainDN"
            Rights   = "GenericRead"
        }
    )

    $manualRows | Format-Table -AutoSize | Out-String | Write-Host
    exit 2
}

Write-Host "[OK]    Running as Domain Admin: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------------
# DELEGATIONS
# ---------------------------------------------------------------------------

Write-Host "--- Delegations ---" -ForegroundColor White

# ---------------------------------------------------------------------------
# 1. Remote Management Users
# ---------------------------------------------------------------------------

try {
    $rmMembers  = Get-ADGroupMember -Identity "Remote Management Users" -Server $DCHostName -ErrorAction Stop
    $isRmMember = @($rmMembers | Where-Object { $_.SID -eq $adAccount.SID }).Count -gt 0

    if ($isRmMember) {
        Write-Action "OK"  "Remote Management Users" "$ServiceAccountName already member"
        $alreadyPresent++
    } else {
        Add-ADGroupMember -Identity "Remote Management Users" -Members $ServiceAccountName `
            -Server $DCHostName -ErrorAction Stop
        Write-Action "SET" "Remote Management Users" "$ServiceAccountName added"
        $applied++
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
        Write-Action "OK"  "Event Log Readers" "$ServiceAccountName already member"
        $alreadyPresent++
    } else {
        Add-ADGroupMember -Identity "Event Log Readers" -Members $ServiceAccountName `
            -Server $DCHostName -ErrorAction Stop
        Write-Action "SET" "Event Log Readers" "$ServiceAccountName added"
        $applied++
    }
} catch {
    Write-Action "FAIL" "Event Log Readers" $_.Exception.Message
    $failed++
}

# ---------------------------------------------------------------------------
# 3. WMI namespace root\MicrosoftDFS -- applied on every DC (P10: soft degradation)
#    Access mask: Enable (0x01) | MethodExecute (0x02) | RemoteAccess (0x20) = 0x23
# ---------------------------------------------------------------------------

$accountSid = $adAccount.SID.Value
$wmiMask    = 0x00000023

$wmiScriptBlock = {
    param($AccountSid, $WmiMask)

    $ErrorActionPreference = "Stop"
    $namespace = "root\MicrosoftDFS"

    $getResult = Invoke-WmiMethod -Namespace $namespace -Class "__SystemSecurity" -Name "GetSD"
    if ($getResult.ReturnValue -ne 0) {
        throw "GetSD failed: $($getResult.ReturnValue)"
    }

    $rawSD = New-Object System.Security.AccessControl.RawSecurityDescriptor($getResult.SD, 0)
    $sid   = New-Object System.Security.Principal.SecurityIdentifier($AccountSid)

    $existingAce = $rawSD.DiscretionaryAcl | Where-Object {
        $_ -is [System.Security.AccessControl.CommonAce] -and
        $_.AceQualifier -eq [System.Security.AccessControl.AceQualifier]::AccessAllowed -and
        $_.SecurityIdentifier -eq $sid -and
        ($_.AccessMask -band $WmiMask) -eq $WmiMask
    }

    if ($existingAce) {
        return "already_present"
    }

    $ace = New-Object System.Security.AccessControl.CommonAce(
        [System.Security.AccessControl.AceFlags]::ContainerInherit,
        [System.Security.AccessControl.AceQualifier]::AccessAllowed,
        $WmiMask,
        $sid,
        $false,
        $null
    )
    $rawSD.DiscretionaryAcl.InsertAce($rawSD.DiscretionaryAcl.Count, $ace)

    $binarySD = New-Object byte[] $rawSD.BinaryLength
    $rawSD.GetBinaryForm($binarySD, 0)

    $setResult = Invoke-WmiMethod -Namespace $namespace -Class "__SystemSecurity" -Name "SetSD" -ArgumentList @(,$binarySD)
    if ($setResult.ReturnValue -ne 0) {
        throw "SetSD failed: $($setResult.ReturnValue)"
    }

    return "applied"
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
                -ArgumentList $accountSid, $wmiMask `
                -ScriptBlock $wmiScriptBlock -ErrorAction Stop

            if ($wmiResult -eq "already_present") {
                Write-Action "OK"  "WMI root\MicrosoftDFS" "ACE already present on $dcFqdn"
                $alreadyPresent++
            } else {
                Write-Action "SET" "WMI root\MicrosoftDFS" "ACE applied on $dcFqdn"
                $applied++
            }
        } catch {
            Write-Action "FAIL" "WMI root\MicrosoftDFS" "Error on $dcFqdn -- $($_.Exception.Message)"
            $failed++
        }
    }
}

# ---------------------------------------------------------------------------
# Helper: Set-AdAclIfMissing
#   Checks whether the service account already has GenericRead on a given AD
#   object. Applies the ACE via dsacls only if absent (idempotent).
#   Updates script-scope counters directly.
# ---------------------------------------------------------------------------

function Set-AdAclIfMissing {
    param(
        [string]$TargetDN,
        [string]$DisplayName,
        [string]$AccountSAM,
        [System.Security.Principal.SecurityIdentifier]$AccountSID,
        [string]$InheritanceFlag = ""
    )
    try {
        $acl    = Get-Acl "AD:\$TargetDN" -ErrorAction Stop
        $sidVal = $AccountSID.Value
        $hasAce = $false
        foreach ($entry in $acl.Access) {
            try {
                $entrySid = $entry.IdentityReference.Translate(
                    [System.Security.Principal.SecurityIdentifier]).Value
                if ($entrySid -eq $sidVal -and
                    ($entry.ActiveDirectoryRights -band
                        [System.DirectoryServices.ActiveDirectoryRights]::GenericRead) -ne 0) {
                    $hasAce = $true
                    break
                }
            } catch {
                # SID translation failed: cannot confirm this ACE belongs to the account.
                # Treat as absent and apply the delegation (fail-safe toward security).
            }
        }

        if ($hasAce) {
            Write-Action "OK"  $DisplayName "ACE already present"
            $script:alreadyPresent++
        } else {
            if ($InheritanceFlag) {
                $output = & dsacls $TargetDN /G "${AccountSAM}:GR" $InheritanceFlag 2>&1
            } else {
                $output = & dsacls $TargetDN /G "${AccountSAM}:GR" 2>&1
            }
            if ($LASTEXITCODE -ne 0) {
                throw "dsacls failed (exit $LASTEXITCODE): $($output -join ' ')"
            }
            Write-Action "SET" $DisplayName "ACE applied"
            $script:applied++
        }
    } catch {
        Write-Action "FAIL" $DisplayName $_.Exception.Message
        $script:failed++
    }
}

# ---------------------------------------------------------------------------
# 4. CN=Password Settings Container -- GenericRead, InheritanceType All (/I:T)
# ---------------------------------------------------------------------------

Set-AdAclIfMissing `
    -TargetDN        "CN=Password Settings Container,CN=System,$DomainDN" `
    -DisplayName     "CN=Password Settings Container" `
    -AccountSAM      $SAMAccount `
    -AccountSID      $adAccount.SID `
    -InheritanceFlag "/I:T"

# ---------------------------------------------------------------------------
# 5. CN=MicrosoftDNS,DC=DomainDnsZones -- GenericRead (P9: robustness)
# ---------------------------------------------------------------------------

Set-AdAclIfMissing `
    -TargetDN    "CN=MicrosoftDNS,DC=DomainDnsZones,$DomainDN" `
    -DisplayName "CN=MicrosoftDNS DomainDnsZones" `
    -AccountSAM  $SAMAccount `
    -AccountSID  $adAccount.SID

# ---------------------------------------------------------------------------
# 6. CN=MicrosoftDNS,DC=ForestDnsZones -- GenericRead (P9: robustness)
# ---------------------------------------------------------------------------

Set-AdAclIfMissing `
    -TargetDN    "CN=MicrosoftDNS,DC=ForestDnsZones,$DomainDN" `
    -DisplayName "CN=MicrosoftDNS ForestDnsZones" `
    -AccountSAM  $SAMAccount `
    -AccountSID  $adAccount.SID

# ---------------------------------------------------------------------------
# 7. CN=MicrosoftDNS,CN=System -- GenericRead (DNS RPC via System container)
# ---------------------------------------------------------------------------

Set-AdAclIfMissing `
    -TargetDN    "CN=MicrosoftDNS,CN=System,$DomainDN" `
    -DisplayName "CN=MicrosoftDNS System (DNS RPC)" `
    -AccountSAM  $SAMAccount `
    -AccountSID  $adAccount.SID

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " SUMMARY" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

$failColor = if ($failed -gt 0) { "Red" } else { "Green" }
Write-Host " Applied        : $applied"        -ForegroundColor Cyan
Write-Host " Already present: $alreadyPresent" -ForegroundColor Green
Write-Host " Failed         : $failed"         -ForegroundColor $failColor
Write-Host ""
Write-Host "Set-LegacyMCPPermissions completed: $applied applied, $alreadyPresent already present, $failed failed"
Write-Host ""

if ($failed -gt 0) { exit 1 } else { exit 0 }
