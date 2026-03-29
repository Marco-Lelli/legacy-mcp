#Requires -Version 5.1
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    LegacyMCP Offline Data Collector - exports AD data to a structured JSON file.

.DESCRIPTION
    Collects Active Directory data across all sections covered by LegacyMCP Core
    and exports it as a single JSON file for offline analysis.
    Read-only. No changes are made to the AD environment.

    The output JSON includes a _metadata block as the first key, containing
    module, version, forest, collected_at (UTC ISO 8601), collector_version,
    and collected_by. This block is required by LegacyMCP for temporal
    comparisons and audit tracing in Profile B-enterprise.

.PARAMETER OutputPath
    Path to the output JSON file. Default: .\ad-data.json

.PARAMETER Server
    Domain Controller to query. Defaults to the closest DC via auto-discovery.

.PARAMETER Credential
    PSCredential to use. If omitted, uses the current user context (gMSA or logged-in user).

.EXAMPLE
    .\Collect-ADData.ps1 -OutputPath C:\export\contoso.json

.EXAMPLE
    .\Collect-ADData.ps1 -Server dc01.contoso.local -OutputPath C:\export\contoso.json
#>

[CmdletBinding()]
param(
    [string]$OutputPath = ".\ad-data.json",
    [string]$Server,
    [System.Management.Automation.PSCredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$commonParams = @{}
if ($Server)     { $commonParams["Server"]     = $Server }
if ($Credential) { $commonParams["Credential"] = $Credential }

function Write-Status([string]$Section, [string]$State) {
    $symbol = if ($State -eq "OK") { "[OK]" } elseif ($State -eq "WARN") { "[WARN]" } else { "[FAIL]" }
    Write-Host "$symbol  $Section"
}

function Invoke-Section([string]$Name, [scriptblock]$Block) {
    try {
        $result = & $Block
        Write-Status $Name "OK"
        return $result
    } catch {
        Write-Status $Name "WARN"
        Write-Warning "$Name`: $_"
        return $null
    }
}

$data = [ordered]@{}

# --- Forest ---
$data["forest"] = Invoke-Section "Forest" {
    Get-ADForest @commonParams | Select-Object Name, ForestMode, SchemaMaster,
        DomainNamingMaster, Sites, Domains, GlobalCatalogs,
        @{N="SchemaVersion"; E={ (Get-ADObject (Get-ADRootDSE @commonParams).schemaNamingContext -Properties objectVersion @commonParams).objectVersion }}
}

# --- Optional Features ---
$data["optional_features"] = Invoke-Section "Optional Features" {
    Get-ADOptionalFeature -Filter * @commonParams | Select-Object Name, EnabledScopes,
        @{N="Enabled"; E={ $_.EnabledScopes.Count -gt 0 }}
}

# --- Schema Extensions ---
$data["schema"] = Invoke-Section "Schema Extensions" {
    $schemaDN = (Get-ADRootDSE @commonParams).schemaNamingContext
    # Microsoft base schema OIDs start with 1.2.840.113556 (Windows) or
    # 2.16.840.1.101.2 (US DoD). Exchange uses 1.2.840.113556 as well.
    # Custom extensions typically use private OIDs outside these prefixes.
    # We identify custom objects by checking that their governsID / attributeID
    # does NOT fall within the Microsoft-reserved OID subtree.
    Get-ADObject -SearchBase $schemaDN -Filter * `
        -Properties lDAPDisplayName, objectClass, adminDescription,
                    governsID, attributeID @commonParams |
        Where-Object {
            $oid = if ($_.governsID) { $_.governsID } else { $_.attributeID }
            $oid -and
            -not $oid.StartsWith("1.2.840.113556") -and
            -not $oid.StartsWith("2.16.840.1.101.2") -and
            -not $oid.StartsWith("1.3.6.1.4.1.311")
        } |
        Select-Object lDAPDisplayName, objectClass, adminDescription, governsID, attributeID |
        Select-Object -First 500
}

# --- Domains ---
$data["domains"] = Invoke-Section "Domains" {
    Get-ADDomain @commonParams | Select-Object Name, DNSRoot, DomainMode,
        PDCEmulator, RIDMaster, InfrastructureMaster, ChildDomains,
        @{N="Forest"; E={ $_.Forest }}
}

# --- Default Password Policy ---
$data["default_password_policy"] = Invoke-Section "Default Password Policy" {
    Get-ADDefaultDomainPasswordPolicy @commonParams | Select-Object ComplexityEnabled,
        LockoutDuration, LockoutObservationWindow, LockoutThreshold,
        MaxPasswordAge, MinPasswordAge, MinPasswordLength, PasswordHistoryCount,
        ReversibleEncryptionEnabled,
        @{N="Domain"; E={ (Get-ADDomain @commonParams).DNSRoot }}
}

# --- Domain Controllers ---
$data["dcs"] = Invoke-Section "Domain Controllers" {
    Get-ADDomainController -Filter * @commonParams | Select-Object Name, HostName,
        IPv4Address, Site, OperatingSystem, OperatingSystemVersion,
        IsGlobalCatalog, IsReadOnly, Enabled,
        @{N="Reachable"; E={ Test-Connection $_.HostName -Count 1 -Quiet }}
}

# --- FSMO Roles ---
$data["fsmo_roles"] = Invoke-Section "FSMO Roles" {
    $forest = Get-ADForest @commonParams
    $domain = Get-ADDomain @commonParams
    [ordered]@{
        SchemaMaster           = $forest.SchemaMaster
        DomainNamingMaster     = $forest.DomainNamingMaster
        PDCEmulator            = $domain.PDCEmulator
        RIDMaster              = $domain.RIDMaster
        InfrastructureMaster   = $domain.InfrastructureMaster
    }
}

# --- EventLog Config ---
$data["eventlog_config"] = Invoke-Section "EventLog Config" {
    $dcs = Get-ADDomainController -Filter * @commonParams
    $results = foreach ($dc in $dcs) {
        try {
            $logs = Get-WinEvent -ListLog "Application","System","Security" -ComputerName $dc.HostName -ErrorAction Stop
            foreach ($log in $logs) {
                [PSCustomObject]@{
                    DC             = $dc.HostName
                    LogName        = $log.LogName
                    MaxSizeBytes   = $log.MaximumSizeInBytes
                    OverflowAction = $log.LogMode
                }
            }
        } catch {
            [PSCustomObject]@{ DC = $dc.HostName; LogName = "ERROR"; MaxSizeBytes = 0; OverflowAction = $_.ToString() }
        }
    }
    $results
}

# --- NTP Config (per DC from registry) ---
$data["ntp_config"] = Invoke-Section "NTP Config" {
    $dcs = Get-ADDomainController -Filter * @commonParams
    foreach ($dc in $dcs) {
        try {
            $reg    = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey("LocalMachine", $dc.HostName)
            $params = $reg.OpenSubKey("SYSTEM\CurrentControlSet\Services\W32Time\Parameters")
            $config = $reg.OpenSubKey("SYSTEM\CurrentControlSet\Services\W32Time\Config")
            $vmic   = $reg.OpenSubKey("SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\VMICTimeProvider")
            [PSCustomObject]@{
                DC                      = $dc.HostName
                NtpServer               = $params.GetValue("NtpServer")
                Type                    = $params.GetValue("Type")
                AnnounceFlags           = $config.GetValue("AnnounceFlags")
                MaxNegPhaseCorrection   = $config.GetValue("MaxNegPhaseCorrection")
                MaxPosPhaseCorrection   = $config.GetValue("MaxPosPhaseCorrection")
                SpecialPollInterval     = $config.GetValue("SpecialPollInterval")
                VMICTimeProviderEnabled = if ($vmic) { $vmic.GetValue("Enabled") } else { $null }
            }
        } catch {
            [PSCustomObject]@{
                DC                      = $dc.HostName
                NtpServer               = $null
                Type                    = $null
                AnnounceFlags           = $null
                MaxNegPhaseCorrection   = $null
                MaxPosPhaseCorrection   = $null
                SpecialPollInterval     = $null
                VMICTimeProviderEnabled = $null
            }
        }
    }
}

# --- SYSVOL ---
$data["sysvol"] = Invoke-Section "SYSVOL" {
    Get-ADDomainController -Filter * @commonParams | ForEach-Object {
        $dcName = $_.HostName
        try {
            $dfsr = Get-WmiObject -Namespace "root\MicrosoftDFS" -Class DfsrReplicatedFolderInfo `
                -ComputerName $dcName -Filter "ReplicatedFolderName='SYSVOL Share'" -ErrorAction Stop
            [PSCustomObject]@{
                DC        = $dcName
                Mechanism = "DFSR"
                State     = $dfsr.State
            }
        } catch {
            [PSCustomObject]@{ DC = $dcName; Mechanism = "Unknown"; State = "Unreachable" }
        }
    }
}

# --- Sites ---
$data["sites"] = Invoke-Section "Sites" {
    Get-ADReplicationSite -Filter * @commonParams | Select-Object Name, Description,
        @{N="Subnets"; E={ (Get-ADReplicationSubnet -Filter "Site -eq '$($_.DistinguishedName)'" @commonParams).Name -join ", " }}
}

# --- Site Links ---
$data["site_links"] = Invoke-Section "Site Links" {
    Get-ADReplicationSiteLink -Filter * @commonParams | Select-Object Name, Cost,
        ReplicationFrequencyInMinutes, SitesIncluded,
        @{N="Transport"; E={ $_.InterSiteTransportProtocol }}
}

# --- Users ---
$data["users"] = Invoke-Section "Users" {
    Get-ADUser -Filter * -Properties Enabled, PasswordNeverExpires, LockedOut,
        LastLogonDate, PasswordLastSet, Description, mail, adminCount,
        TrustedForDelegation, TrustedToAuthForDelegation,
        "msDS-AllowedToDelegateTo" @commonParams |
        Select-Object -First 5000 |
        ForEach-Object {
            [PSCustomObject]@{
                SamAccountName              = $_.SamAccountName
                DisplayName                 = $_.DisplayName
                UserPrincipalName           = $_.UserPrincipalName
                DistinguishedName           = $_.DistinguishedName
                Mail                        = $_.mail
                Enabled                     = $_.Enabled
                PasswordNeverExpires        = $_.PasswordNeverExpires
                LockedOut                   = $_.LockedOut
                LastLogonDate               = $_.LastLogonDate
                PasswordLastSet             = $_.PasswordLastSet
                Description                 = $_.Description
                AdminCount                  = $_.adminCount
                TrustedForDelegation        = $_.TrustedForDelegation
                TrustedToAuthForDelegation  = $_.TrustedToAuthForDelegation
                AllowedToDelegateTo         = $_.("msDS-AllowedToDelegateTo")
            }
        }
}

# --- Privileged Accounts ---
$data["privileged_accounts"] = Invoke-Section "Privileged Accounts" {
    $privilegedGroups = @(
        "Domain Admins", "Enterprise Admins", "Schema Admins",
        "Administrators", "Account Operators", "Backup Operators",
        "Print Operators", "Server Operators"
    )
    $seen = @{}
    foreach ($groupName in $privilegedGroups) {
        try {
            Get-ADGroupMember -Identity $groupName -Recursive @commonParams |
                Where-Object { $_.objectClass -eq "user" -and -not $seen[$_.SamAccountName] } |
                ForEach-Object {
                    $seen[$_.SamAccountName] = $true
                    [PSCustomObject]@{
                        SamAccountName = $_.SamAccountName
                        Group          = $groupName
                    }
                }
        } catch { }
    }
}

# --- Groups ---
$data["groups"] = Invoke-Section "Groups" {
    Get-ADGroup -Filter * -Properties adminCount @commonParams |
        ForEach-Object {
            # Get-ADGroupMember handles range retrieval (large groups > MaxPageSize).
            # $_.Members.Count truncates at the LDAP page boundary for large groups
            # like Domain Computers, returning 0 when membership exceeds ~1500.
            $count = try {
                (Get-ADGroupMember -Identity $_.DistinguishedName @commonParams |
                    Measure-Object).Count
            } catch { -1 }
            [PSCustomObject]@{
                Name              = $_.Name
                SamAccountName    = $_.SamAccountName
                DistinguishedName = $_.DistinguishedName
                GroupCategory     = $_.GroupCategory.ToString()
                GroupScope        = $_.GroupScope.ToString()
                MemberCount       = $count
                AdminCount        = $_.adminCount
            }
        }
}

# --- Group Members (flat table -- one row per member per group) ---
# Iterates all AD groups. For each group, emits one row per direct member
# with identity and object class. Nested group membership is NOT expanded
# here -- use privileged_groups for recursive expansion of sensitive groups.
# Groups with no members produce no rows (not an error).
# MemberEnabled is null for members that are not user or computer objects.
$data["group_members"] = Invoke-Section "Group Members" {
    Get-ADGroup -Filter * @commonParams | ForEach-Object {
        $groupName = $_.Name
        $groupDN   = $_.DistinguishedName
        try {
            Get-ADGroupMember -Identity $groupDN @commonParams | ForEach-Object {
                $member = $_
                $enabled = $null
                if ($member.objectClass -eq "user") {
                    try {
                        $enabled = (Get-ADUser -Identity $member.distinguishedName `
                            -Properties Enabled @commonParams).Enabled
                    } catch { }
                } elseif ($member.objectClass -eq "computer") {
                    try {
                        $enabled = (Get-ADComputer -Identity $member.distinguishedName `
                            -Properties Enabled @commonParams).Enabled
                    } catch { }
                }
                [PSCustomObject]@{
                    GroupName                = $groupName
                    MemberSamAccountName     = $member.SamAccountName
                    MemberDisplayName        = $member.name
                    MemberObjectClass        = $member.objectClass
                    MemberDistinguishedName  = $member.distinguishedName
                    MemberEnabled            = $enabled
                }
            }
        } catch { }
    }
}

# --- Privileged Groups (with members) ---
$data["privileged_groups"] = Invoke-Section "Privileged Groups" {
    $names = @("Domain Admins","Enterprise Admins","Schema Admins","Administrators",
               "Account Operators","Backup Operators","Print Operators","Server Operators")
    foreach ($name in $names) {
        try {
            $members = Get-ADGroupMember -Identity $name -Recursive @commonParams |
                Select-Object SamAccountName, objectClass, distinguishedName
            [PSCustomObject]@{ Group = $name; Members = $members }
        } catch {
            [PSCustomObject]@{ Group = $name; Members = @() }
        }
    }
}

# --- OUs ---
$data["ous"] = Invoke-Section "OUs" {
    Get-ADOrganizationalUnit -Filter * -Properties gpLink, gPOptions @commonParams |
        Select-Object Name, DistinguishedName,
            @{N="BlockedInheritance"; E={ ($_.gPOptions -band 1) -eq 1 }},
            @{N="LinkedGPOs";         E={ $_.gpLink }}
}

# --- GPO Inventory ---
$data["gpos"] = Invoke-Section "GPO Inventory" {
    try {
        Get-GPO -All @commonParams | Select-Object DisplayName, Id, GpoStatus,
            CreationTime, ModificationTime, Owner
    } catch {
        Write-Warning "GPO cmdlets not available - skipping GPO inventory"
        @()
    }
}

# --- GPO Links ---
# Collects GPO links from the domain root and every OU.
# The previous implementation queried only the domain root, which missed
# all OU-level links -- the majority in most environments.
# Get-GPInheritance.GpoLinks returns DIRECT links on each target only
# (not inherited), so the same GPO linked to multiple OUs appears as
# multiple rows, each with its own Target field.
$data["gpo_links"] = Invoke-Section "GPO Links" {
    try {
        $domainDN = (Get-ADDomain @commonParams).DistinguishedName
        $ouDNs    = Get-ADOrganizationalUnit -Filter * @commonParams |
                        Select-Object -ExpandProperty DistinguishedName
        $targets  = @($domainDN) + @($ouDNs)
        $targets | ForEach-Object {
            $target = $_
            try {
                Get-GPInheritance -Target $target @commonParams |
                    Select-Object -ExpandProperty GpoLinks |
                    Select-Object DisplayName, GpoId, Enabled, Enforced, Target, Order
            } catch { }
        }
    } catch { @() }
}

# --- Blocked Inheritance OUs ---
$data["blocked_inheritance"] = Invoke-Section "Blocked Inheritance" {
    Get-ADOrganizationalUnit -Filter * -Properties gPOptions @commonParams |
        Where-Object { ($_.gPOptions -band 1) -eq 1 } |
        Select-Object Name, DistinguishedName
}

# --- Trusts ---
$data["trusts"] = Invoke-Section "Trusts" {
    Get-ADTrust -Filter * @commonParams | Select-Object Name, Direction, TrustType,
        TrustAttributes, SelectiveAuthentication, SIDFilteringForestAware,
        SIDFilteringQuarantined, DisallowTransivity, DistinguishedName
}

# --- Fine-Grained Password Policies ---
$data["fgpp"] = Invoke-Section "FGPP" {
    Get-ADFineGrainedPasswordPolicy -Filter * @commonParams | Select-Object Name,
        Precedence, MinPasswordLength, PasswordHistoryCount, ComplexityEnabled,
        MaxPasswordAge, MinPasswordAge, LockoutThreshold, LockoutDuration,
        LockoutObservationWindow, ReversibleEncryptionEnabled,
        @{N="AppliesTo"; E={ ($_ | Get-ADFineGrainedPasswordPolicySubject @commonParams).Name -join ", " }}
}

# --- DNS ---
$data["dns"] = Invoke-Section "DNS Zones" {
    try {
        $dcs = (Get-ADDomainController -Filter * @commonParams).HostName
        $dc = $dcs | Select-Object -First 1
        Get-DnsServerZone -ComputerName $dc | Select-Object ZoneName, ZoneType,
            IsDsIntegrated, ReplicationScope, IsReverseLookupZone, IsAutoCreated
    } catch { @() }
}

# --- DNS Forwarders ---
$data["dns_forwarders"] = Invoke-Section "DNS Forwarders" {
    try {
        $dcs = (Get-ADDomainController -Filter * @commonParams).HostName
        foreach ($dc in $dcs) {
            try {
                $fwd = Get-DnsServerForwarder -ComputerName $dc
                [PSCustomObject]@{ DC = $dc; Forwarders = $fwd.IPAddress -join ", "; UseRootHint = $fwd.UseRootHint }
            } catch {
                [PSCustomObject]@{ DC = $dc; Forwarders = "UNREACHABLE"; UseRootHint = $null }
            }
        }
    } catch { @() }
}

# --- Computers ---
$data["computers"] = Invoke-Section "Computers" {
    Get-ADComputer -Filter * -Properties OperatingSystem, OperatingSystemVersion,
        Enabled, LastLogonDate, PasswordLastSet, Description,
        ServicePrincipalNames, isCriticalSystemObject,
        TrustedForDelegation, TrustedToAuthForDelegation,
        "msDS-AllowedToDelegateTo" @commonParams |
        Select-Object -First 10000 |
        ForEach-Object {
            $isCNO = $_.ServicePrincipalNames -like "*MSClusterVirtualServer*"
            $isVCO = (-not $isCNO) -and $_.isCriticalSystemObject
            [PSCustomObject]@{
                Name                       = $_.Name
                DistinguishedName          = $_.DistinguishedName
                OperatingSystem            = $_.OperatingSystem
                OperatingSystemVersion     = $_.OperatingSystemVersion
                Enabled                    = $_.Enabled
                LastLogonDate              = $_.LastLogonDate
                PasswordLastSet            = $_.PasswordLastSet
                Description                = $_.Description
                IsCNO                      = [bool]$isCNO
                IsVCO                      = [bool]$isVCO
                TrustedForDelegation       = $_.TrustedForDelegation
                TrustedToAuthForDelegation = $_.TrustedToAuthForDelegation
                AllowedToDelegateTo        = $_.("msDS-AllowedToDelegateTo")
            }
        }
}

# --- PKI / CA Discovery ---
$data["pki"] = Invoke-Section "PKI / CA Discovery" {
    $configDN = (Get-ADRootDSE @commonParams).configurationNamingContext
    $enrollmentDN = "CN=Enrollment Services,CN=Public Key Services,CN=Services,$configDN"
    try {
        Get-ADObject -SearchBase $enrollmentDN -Filter * @commonParams |
            Select-Object Name, DistinguishedName, ObjectClass
    } catch { @() }
}

# --- Export ---

# Pre-check: if output file already exists, rename it before overwriting.
# This prevents silent data loss if the collector is run twice on the same path
# (e.g. append pipelines, automation scripts, repeated manual runs).
try {
    if (Test-Path -LiteralPath $OutputPath) {
        $timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupPath = [System.IO.Path]::ChangeExtension($OutputPath, $null).TrimEnd('.') `
                      + "_backup_$timestamp.json"
        Rename-Item -LiteralPath $OutputPath -NewName (Split-Path $backupPath -Leaf)
        Write-Status "Export pre-check" "WARN"
        Write-Warning "Output file already existed - renamed to: $(Split-Path $backupPath -Leaf)"
    }
} catch {
    Write-Status "Export pre-check" "FAIL"
    throw "Failed to rename existing output file: $_"
}

# Build metadata and export object.
try {
    $forestName = if ($data["forest"] -and $data["forest"].Name) {
        $data["forest"].Name
    } else {
        "unknown"
    }

    $metadata = [ordered]@{
        module            = "ad-core"
        version           = "1.0"
        forest            = $forestName
        collected_at      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        collector_version = "1.4"
        collected_by      = "$env:USERDOMAIN\$env:USERNAME"
    }

    $export = [ordered]@{ _metadata = $metadata }
    foreach ($key in $data.Keys) { $export[$key] = $data[$key] }
} catch {
    Write-Status "Build metadata" "FAIL"
    throw "Failed to build export object: $_"
}

# Write file.
try {
    Write-Host ""
    Write-Host "Exporting to $OutputPath ..."
    $jsonContent = $export | ConvertTo-Json -Depth 20 -Compress
    $jsonContent | Out-File -FilePath $OutputPath -Encoding UTF8 -NoClobber
} catch {
    Write-Status "Write file" "FAIL"
    throw "Failed to write output file '$OutputPath': $_"
}

# Post-check: verify the written file is valid JSON.
# Catches serialization errors (e.g. ConvertTo-Json truncation, encoding issues).
try {
    $written = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8
    $null = $written | ConvertFrom-Json
    Write-Host "Done. File size: $([Math]::Round((Get-Item $OutputPath).Length / 1KB, 1)) KB"
    Write-Status "Export integrity" "OK"
} catch {
    $corruptPath = [System.IO.Path]::ChangeExtension($OutputPath, $null).TrimEnd('.') + "_corrupt.json"
    Rename-Item -LiteralPath $OutputPath -NewName (Split-Path $corruptPath -Leaf)
    Write-Status "Export integrity" "FAIL"
    throw "JSON validation failed -- output renamed to: $(Split-Path $corruptPath -Leaf). Error: $_"
}
