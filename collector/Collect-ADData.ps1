#Requires -Version 5.1
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    LegacyMCP Offline Data Collector v1.6.1 - exports AD data to a structured JSON file.

.DESCRIPTION
    Collects Active Directory data across all sections covered by LegacyMCP Core
    and exports it as a single JSON file for offline analysis.
    Read-only. No changes are made to the AD environment.

    The output JSON includes a _metadata block as the first key, containing
    module, version, forest, collected_at (UTC ISO 8601), collector_version,
    collected_by, and collection_summary (section counts and log file path).
    This block is required by LegacyMCP for temporal comparisons and audit
    tracing in Profile B-enterprise.

    A companion .log file is written alongside the JSON with one timestamped
    entry per section. Use -Verbose to include per-section duration timing.

.PARAMETER OutputPath
    Path to the output JSON file.
    Default: .\<forest>_ad-data.json (resolved from the forest name at runtime).
    The companion log file is written to the same directory with the same stem
    and a .log extension (e.g. contoso.local_ad-data.log).

    If the file already exists, it is renamed with a timestamp suffix before
    the new export is written. The original data is never silently overwritten.
    Use a dedicated folder to keep exports organized by customer and date.

.PARAMETER Server
    FQDN or NetBIOS name of the Domain Controller to query.
    If omitted, PowerShell auto-discovers the closest DC for the current
    user's domain.

.PARAMETER Credential
    Credentials to use for all AD queries.
    If omitted, the script uses the current user context (recommended when
    running as a domain user with appropriate rights, or as a gMSA).

    To build a credential object interactively:
        $cred = Get-Credential

.EXAMPLE
    .\Collect-ADData.ps1

    Exports to .\<forest>_ad-data.json in the current directory.
    Log written to .\<forest>_ad-data.log.

.EXAMPLE
    .\Collect-ADData.ps1 -OutputPath C:\export\contoso.json

.EXAMPLE
    .\Collect-ADData.ps1 -Server dc01.contoso.local -OutputPath C:\export\contoso.json

.EXAMPLE
    .\Collect-ADData.ps1 -Verbose

    Adds per-section duration timing to the log file and console.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "",
    [string]$Server,
    [System.Management.Automation.PSCredential]$Credential
)

# Import DC inventory module
$modulePath = Join-Path $PSScriptRoot "modules\DomainControllers.psm1"
Import-Module $modulePath -Force

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:sectionsOK    = 0
$script:sectionsWarn  = 0
$script:sectionsError = 0
$script:LogPath       = $null

$commonParams = @{}
if ($Server)     { $commonParams["Server"]     = $Server }
if ($Credential) { $commonParams["Credential"] = $Credential }

# ---------------------------------------------------------------------------
# Write-CollectorLog
# Writes a timestamped entry to the log file and to the appropriate console
# stream. Increments session counters for INFO, WARN, and ERROR levels.
# VERBOSE entries are written to file only when -Verbose is active.
# ---------------------------------------------------------------------------
function Write-CollectorLog {
    param(
        [string]$Level,
        [string]$Section,
        [string]$Message
    )
    $timestamp    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $levelField   = "[$Level]".PadRight(10)
    $sectionField = $Section.PadRight(18)
    $line         = "[$timestamp] $levelField $sectionField $Message"

    if ($script:LogPath) {
        if ($Level -ne "VERBOSE" -or $VerbosePreference -ne "SilentlyContinue") {
            $line | Out-File -FilePath $script:LogPath -Encoding UTF8 -Append
        }
    }

    switch ($Level) {
        "INFO" {
            Write-Host $line -ForegroundColor Green
            $script:sectionsOK++
        }
        "WARN" {
            Write-Warning $line
            $script:sectionsWarn++
        }
        "ERROR" {
            Write-Error $line -ErrorAction Continue
            $script:sectionsError++
        }
        "VERBOSE" {
            Write-Verbose $line
        }
    }
}

# ---------------------------------------------------------------------------
# Invoke-Section
# Executes a data-collection scriptblock with timing and error handling.
# On success: logs VERBOSE with duration, returns the result.
# On failure: logs ERROR with exception message, returns $null.
# The caller is responsible for logging INFO with the section count.
# ---------------------------------------------------------------------------
function Invoke-Section([string]$Name, [scriptblock]$Block) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $Block
        $sw.Stop()
        Write-CollectorLog -Level VERBOSE -Section $Name `
            -Message "duration: $([math]::Round($sw.Elapsed.TotalSeconds, 1))s"
        return $result
    } catch {
        $sw.Stop()
        Write-CollectorLog -Level ERROR -Section $Name `
            -Message "exception: $($_.Exception.Message)"
        return $null
    }
}

# ---------------------------------------------------------------------------
# Resolve output paths
# A lightweight Get-ADForest call provides the forest name before collection
# starts so that OutputPath and LogPath can be resolved for the session header.
# The full Forest section runs again during collection -- this is acceptable.
# ---------------------------------------------------------------------------
$startTime = Get-Date

$forestNameEarly = try { (Get-ADForest @commonParams).Name } catch { "unknown" }
$dcNameEarly = if ($Server) {
    $Server
} else {
    try { (Get-ADDomainController -Discover @commonParams).HostName } catch { "auto" }
}

if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) `
        "$($forestNameEarly)_ad-data.json"
}
$OutputPath     = [System.IO.Path]::GetFullPath($OutputPath)
$script:LogPath = [System.IO.Path]::ChangeExtension($OutputPath, ".log")

# ---------------------------------------------------------------------------
# Session header
# ---------------------------------------------------------------------------
$sep = "=" * 80
@(
    $sep,
    "LegacyMCP Collector v1.5 -- raccolta avviata",
    "Forest : $forestNameEarly",
    "DC     : $dcNameEarly",
    "Output : $OutputPath",
    "Log    : $($script:LogPath)",
    "Start  : $(Get-Date $startTime -Format 'yyyy-MM-dd HH:mm:ss')",
    $sep
) | Out-File -FilePath $script:LogPath -Encoding UTF8

$data = [ordered]@{}

# ---------------------------------------------------------------------------
# Data collection
# ---------------------------------------------------------------------------

# --- Forest ---
$data["forest"] = Invoke-Section "Forest" {
    Get-ADForest @commonParams | Select-Object Name, ForestMode, SchemaMaster,
        DomainNamingMaster, Sites, Domains, GlobalCatalogs,
        @{N="SchemaVersion"; E={ (Get-ADObject (Get-ADRootDSE @commonParams).schemaNamingContext -Properties objectVersion @commonParams).objectVersion }}
}
if ($null -ne $data["forest"]) {
    Write-CollectorLog -Level INFO -Section "Forest" -Message "collected: $($data['forest'].Name)"
}

# --- Optional Features ---
$data["optional_features"] = Invoke-Section "Optional Features" {
    Get-ADOptionalFeature -Filter * @commonParams | Select-Object Name, EnabledScopes,
        @{N="Enabled"; E={ $_.EnabledScopes.Count -gt 0 }}
}
if ($null -ne $data["optional_features"]) {
    Write-CollectorLog -Level INFO -Section "Optional Features" `
        -Message "collected: $(@($data['optional_features']).Count)"
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
if ($null -ne $data["schema"]) {
    Write-CollectorLog -Level INFO -Section "Schema Extensions" `
        -Message "collected: $(@($data['schema']).Count) custom extensions"
}

# --- Domains ---
$data["domains"] = Invoke-Section "Domains" {
    Get-ADDomain @commonParams | Select-Object Name, DNSRoot, DomainMode,
        PDCEmulator, RIDMaster, InfrastructureMaster, ChildDomains,
        @{N="Forest"; E={ $_.Forest }}
}
if ($null -ne $data["domains"]) {
    Write-CollectorLog -Level INFO -Section "Domains" -Message "collected"
}

# --- Default Password Policy ---
$data["default_password_policy"] = Invoke-Section "Default Password Policy" {
    Get-ADDefaultDomainPasswordPolicy @commonParams | Select-Object ComplexityEnabled,
        LockoutDuration, LockoutObservationWindow, LockoutThreshold,
        MaxPasswordAge, MinPasswordAge, MinPasswordLength, PasswordHistoryCount,
        ReversibleEncryptionEnabled,
        @{N="Domain"; E={ (Get-ADDomain @commonParams).DNSRoot }}
}
if ($null -ne $data["default_password_policy"]) {
    Write-CollectorLog -Level INFO -Section "Default Password Policy" -Message "collected"
}

# --- Domain Controllers ---
$data["dcs"] = Invoke-Section "Domain Controllers" {
    Get-ADDomainController -Filter * @commonParams | Select-Object Name, HostName,
        IPv4Address, Site, OperatingSystem, OperatingSystemVersion,
        IsGlobalCatalog, IsReadOnly, Enabled,
        @{N="Reachable"; E={ Test-Connection $_.HostName -Count 1 -Quiet }}
}
if ($null -ne $data["dcs"]) {
    Write-CollectorLog -Level INFO -Section "Domain Controllers" `
        -Message "collected: $(@($data['dcs']).Count)"
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
if ($null -ne $data["fsmo_roles"]) {
    Write-CollectorLog -Level INFO -Section "FSMO Roles" -Message "collected"
}

# --- EventLog Config ---
$data["eventlog_config"] = Invoke-Section "EventLog Config" {
    Get-EventLogConfigData -CommonParams $commonParams
}
if ($null -ne $data["eventlog_config"]) {
    Write-CollectorLog -Level INFO -Section "EventLog Config" `
        -Message "collected: $(@($data['eventlog_config']).Count) entries"
}

# --- NTP Config (per DC from registry) ---
$data["ntp_config"] = Invoke-Section "NTP Config" {
    Get-NtpConfigData -CommonParams $commonParams
}
if ($null -ne $data["ntp_config"]) {
    Write-CollectorLog -Level INFO -Section "NTP Config" `
        -Message "collected: $(@($data['ntp_config']).Count) DCs"
}

# --- SYSVOL ---
$data["sysvol"] = Invoke-Section "SYSVOL" {
    Get-SysvolData -CommonParams $commonParams
}
if ($null -ne $data["sysvol"]) {
    Write-CollectorLog -Level INFO -Section "SYSVOL" `
        -Message "collected: $(@($data['sysvol']).Count) DCs"
}

# --- DC Windows Features ---
$data["dc_windows_features"] = Invoke-Section "DC Windows Features" {
    Get-DCWindowsFeaturesData -CommonParams $commonParams
}
if ($null -ne $data["dc_windows_features"]) {
    Write-CollectorLog -Level INFO -Section "DC Windows Features" `
        -Message "collected: $(@($data['dc_windows_features']).Count) DCs"
}

# --- DC Services ---
$data["dc_services"] = Invoke-Section "DC Services" {
    Get-DCServicesData -CommonParams $commonParams
}
if ($null -ne $data["dc_services"]) {
    Write-CollectorLog -Level INFO -Section "DC Services" `
        -Message "collected: $(@($data['dc_services']).Count) DCs"
}

# --- DC Installed Software ---
$data["dc_installed_software"] = Invoke-Section "DC Installed Software" {
    Get-DCInstalledSoftwareData -CommonParams $commonParams
}
if ($null -ne $data["dc_installed_software"]) {
    Write-CollectorLog -Level INFO -Section "DC Installed Software" `
        -Message "collected: $(@($data['dc_installed_software']).Count) DCs"
}

# --- Sites ---
$data["sites"] = Invoke-Section "Sites" {
    Get-ADReplicationSite -Filter * @commonParams | Select-Object Name, Description,
        @{N="Subnets"; E={ (Get-ADReplicationSubnet -Filter "Site -eq '$($_.DistinguishedName)'" @commonParams).Name -join ", " }}
}
if ($null -ne $data["sites"]) {
    Write-CollectorLog -Level INFO -Section "Sites" `
        -Message "collected: $(@($data['sites']).Count)"
}

# --- Site Links ---
$data["site_links"] = Invoke-Section "Site Links" {
    Get-ADReplicationSiteLink -Filter * @commonParams | Select-Object Name, Cost,
        ReplicationFrequencyInMinutes, SitesIncluded,
        @{N="Transport"; E={ $_.InterSiteTransportProtocol }}
}
if ($null -ne $data["site_links"]) {
    Write-CollectorLog -Level INFO -Section "Site Links" `
        -Message "collected: $(@($data['site_links']).Count)"
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
if ($null -ne $data["users"]) {
    $usersArr = @($data["users"])
    $enabled  = @($usersArr | Where-Object { $_.Enabled -eq $true }).Count
    $disabled = $usersArr.Count - $enabled
    Write-CollectorLog -Level INFO -Section "Users" `
        -Message "collected: $($usersArr.Count)  (enabled: $enabled, disabled: $disabled)"
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
if ($null -ne $data["privileged_accounts"]) {
    Write-CollectorLog -Level INFO -Section "Privileged Accounts" `
        -Message "collected: $(@($data['privileged_accounts']).Count)"
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
if ($null -ne $data["groups"]) {
    Write-CollectorLog -Level INFO -Section "Groups" `
        -Message "collected: $(@($data['groups']).Count)"
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
if ($null -ne $data["group_members"]) {
    Write-CollectorLog -Level INFO -Section "Group Members" `
        -Message "collected: $(@($data['group_members']).Count) entries"
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
if ($null -ne $data["privileged_groups"]) {
    Write-CollectorLog -Level INFO -Section "Privileged Groups" `
        -Message "collected: $(@($data['privileged_groups']).Count) groups"
}

# --- OUs ---
$data["ous"] = Invoke-Section "OUs" {
    Get-ADOrganizationalUnit -Filter * -Properties gpLink, gPOptions @commonParams |
        Select-Object Name, DistinguishedName,
            @{N="BlockedInheritance"; E={ ($_.gPOptions -band 1) -eq 1 }},
            @{N="LinkedGPOs";         E={ $_.gpLink }}
}
if ($null -ne $data["ous"]) {
    Write-CollectorLog -Level INFO -Section "OUs" `
        -Message "collected: $(@($data['ous']).Count)"
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
if ($null -ne $data["gpos"]) {
    Write-CollectorLog -Level INFO -Section "GPO Inventory" `
        -Message "collected: $(@($data['gpos']).Count)"
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
if ($null -ne $data["gpo_links"]) {
    Write-CollectorLog -Level INFO -Section "GPO Links" `
        -Message "collected: $(@($data['gpo_links']).Count)"
}

# --- Blocked Inheritance ---
$data["blocked_inheritance"] = Invoke-Section "Blocked Inheritance" {
    Get-ADOrganizationalUnit -Filter * -Properties gPOptions @commonParams |
        Where-Object { ($_.gPOptions -band 1) -eq 1 } |
        Select-Object Name, DistinguishedName
}
if ($null -ne $data["blocked_inheritance"]) {
    Write-CollectorLog -Level INFO -Section "Blocked Inheritance" `
        -Message "collected: $(@($data['blocked_inheritance']).Count)"
}

# --- Trusts ---
$data["trusts"] = Invoke-Section "Trusts" {
    Get-ADTrust -Filter * @commonParams | Select-Object Name, Direction, TrustType,
        TrustAttributes, SelectiveAuthentication, SIDFilteringForestAware,
        SIDFilteringQuarantined, DisallowTransivity, DistinguishedName
}
if ($null -ne $data["trusts"]) {
    Write-CollectorLog -Level INFO -Section "Trusts" `
        -Message "collected: $(@($data['trusts']).Count)"
}

# --- Fine-Grained Password Policies ---
$data["fgpp"] = Invoke-Section "FGPP" {
    Get-ADFineGrainedPasswordPolicy -Filter * @commonParams | Select-Object Name,
        Precedence, MinPasswordLength, PasswordHistoryCount, ComplexityEnabled,
        MaxPasswordAge, MinPasswordAge, LockoutThreshold, LockoutDuration,
        LockoutObservationWindow, ReversibleEncryptionEnabled,
        @{N="AppliesTo"; E={ ($_ | Get-ADFineGrainedPasswordPolicySubject @commonParams).Name -join ", " }}
}
if ($null -ne $data["fgpp"]) {
    Write-CollectorLog -Level INFO -Section "FGPP" `
        -Message "collected: $(@($data['fgpp']).Count)"
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
if ($null -ne $data["dns"]) {
    Write-CollectorLog -Level INFO -Section "DNS Zones" `
        -Message "collected: $(@($data['dns']).Count)"
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
if ($null -ne $data["dns_forwarders"]) {
    Write-CollectorLog -Level INFO -Section "DNS Forwarders" `
        -Message "collected: $(@($data['dns_forwarders']).Count) DCs"
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
if ($null -ne $data["computers"]) {
    $computersArr   = @($data["computers"])
    $enabledComp    = @($computersArr | Where-Object { $_.Enabled -eq $true }).Count
    $disabledComp   = $computersArr.Count - $enabledComp
    Write-CollectorLog -Level INFO -Section "Computers" `
        -Message "collected: $($computersArr.Count)  (enabled: $enabledComp, disabled: $disabledComp)"
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
if ($null -ne $data["pki"]) {
    Write-CollectorLog -Level INFO -Section "PKI / CA Discovery" `
        -Message "collected: $(@($data['pki']).Count) CAs"
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

# Pre-check: if output file already exists, rename it before overwriting.
# This prevents silent data loss if the collector is run twice on the same path
# (e.g. append pipelines, automation scripts, repeated manual runs).
try {
    if (Test-Path -LiteralPath $OutputPath) {
        $timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupPath = [System.IO.Path]::ChangeExtension($OutputPath, $null).TrimEnd('.') `
                      + "_backup_$timestamp.json"
        Rename-Item -LiteralPath $OutputPath -NewName (Split-Path $backupPath -Leaf)
        Write-Host "[WARN] Output file already existed - renamed to: $(Split-Path $backupPath -Leaf)" `
            -ForegroundColor Yellow
        Write-Warning "Output file already existed - renamed to: $(Split-Path $backupPath -Leaf)"
    }
} catch {
    throw "Failed to rename existing output file: $_"
}

# Build metadata and export object.
try {
    $forestName = if ($data["forest"] -and $data["forest"].Name) {
        $data["forest"].Name
    } else {
        $forestNameEarly
    }

    $metadata = [ordered]@{
        module             = "ad-core"
        version            = "1.0"
        forest             = $forestName
        collected_at       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        collector_version  = "1.6.1"
        collected_by       = "$env:USERDOMAIN\$env:USERNAME"
        collection_summary = [ordered]@{
            sections_ok    = $script:sectionsOK
            sections_warn  = $script:sectionsWarn
            sections_error = $script:sectionsError
            log_file       = $script:LogPath
        }
    }

    $export = [ordered]@{ _metadata = $metadata }
    foreach ($key in $data.Keys) { $export[$key] = $data[$key] }
} catch {
    throw "Failed to build export object: $_"
}

# Write file.
try {
    Write-Host ""
    Write-Host "Exporting to $OutputPath ..."
    $jsonContent = $export | ConvertTo-Json -Depth 20 -Compress
    $jsonContent | Out-File -FilePath $OutputPath -Encoding UTF8 -NoClobber
} catch {
    throw "Failed to write output file '$OutputPath': $_"
}

# Post-check: verify the written file is valid JSON.
# Catches serialization errors (e.g. ConvertTo-Json truncation, encoding issues).
try {
    $written = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8
    $null = $written | ConvertFrom-Json
    Write-Host "Done. File size: $([Math]::Round((Get-Item $OutputPath).Length / 1KB, 1)) KB"
} catch {
    $corruptPath = [System.IO.Path]::ChangeExtension($OutputPath, $null).TrimEnd('.') + "_corrupt.json"
    Rename-Item -LiteralPath $OutputPath -NewName (Split-Path $corruptPath -Leaf)
    throw "JSON validation failed -- output renamed to: $(Split-Path $corruptPath -Leaf). Error: $_"
}

# ---------------------------------------------------------------------------
# Session footer
# ---------------------------------------------------------------------------
$endTime       = Get-Date
$duration      = New-TimeSpan -Start $startTime -End $endTime
$durationStr   = "$([int]$duration.TotalMinutes)m $($duration.Seconds)s"
$totalSections = $script:sectionsOK + $script:sectionsWarn + $script:sectionsError

@(
    "",
    $sep,
    "Raccolta completata -- $forestName",
    "Sezioni OK : $($script:sectionsOK)/$totalSections",
    "Warnings   : $($script:sectionsWarn)",
    "Errors     : $($script:sectionsError)",
    "End        : $(Get-Date $endTime -Format 'yyyy-MM-dd HH:mm:ss')  (duration: $durationStr)",
    $sep
) | Out-File -FilePath $script:LogPath -Encoding UTF8 -Append
