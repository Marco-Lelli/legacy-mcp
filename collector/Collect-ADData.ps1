#Requires -Version 5.1
#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    LegacyMCP Offline Data Collector v1.7.0 - exports AD data to a structured JSON file.

.DESCRIPTION
    Collects Active Directory data across all sections covered by LegacyMCP Core
    and exports it as a single JSON file for offline analysis.
    Read-only. No changes are made to the AD environment.

    The output JSON includes a _metadata block as the first key, containing
    module, version, forest, domain (DNS root of the domain hosting the
    target DC -- see -Server, distinct from forest in cross-forest trust
    scenarios), collected_at (UTC ISO 8601), collector_version, collected_by,
    elevated (whether the PowerShell session ran elevated; null when it could
    not be determined), and collection_summary (section counts and log file
    path).

    Run PowerShell as Administrator. In some AD environments a non-elevated
    session cannot read userAccountControl, which silently empties Enabled,
    PasswordNeverExpires and the delegation flags even when the account has
    adequate AD permissions.
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

# Import collector modules
# Logging.psm1 first: every other module may call Write-SafeCollectorLog.
# Membership.psm1 next: Groups.psm1 and Users.psm1 call its helpers.
$modulePath = Join-Path $PSScriptRoot "modules\Logging.psm1"
Import-Module $modulePath -Force
$modulePath = Join-Path $PSScriptRoot "modules\Membership.psm1"
Import-Module $modulePath -Force
$modulePath = Join-Path $PSScriptRoot "modules\DomainControllers.psm1"
Import-Module $modulePath -Force
$modulePath = Join-Path $PSScriptRoot "modules\Forest.psm1"
Import-Module $modulePath -Force
$modulePath = Join-Path $PSScriptRoot "modules\Domains.psm1"
Import-Module $modulePath -Force
$modulePath = Join-Path $PSScriptRoot "modules\Sites.psm1"
Import-Module $modulePath -Force
$modulePath = Join-Path $PSScriptRoot "modules\Users.psm1"
Import-Module $modulePath -Force
$modulePath = Join-Path $PSScriptRoot "modules\Groups.psm1"
Import-Module $modulePath -Force
$modulePath = Join-Path $PSScriptRoot "modules\OUs.psm1"
Import-Module $modulePath -Force
$modulePath = Join-Path $PSScriptRoot "modules\GPO.psm1"
Import-Module $modulePath -Force
$modulePath = Join-Path $PSScriptRoot "modules\Trusts.psm1"
Import-Module $modulePath -Force
$modulePath = Join-Path $PSScriptRoot "modules\FGPP.psm1"
Import-Module $modulePath -Force
$modulePath = Join-Path $PSScriptRoot "modules\DNS.psm1"
Import-Module $modulePath -Force
$modulePath = Join-Path $PSScriptRoot "modules\PKI.psm1"
Import-Module $modulePath -Force
$modulePath = Join-Path $PSScriptRoot "modules\Schema.psm1"
Import-Module $modulePath -Force
$modulePath = Join-Path $PSScriptRoot "modules\FSP.psm1"
Import-Module $modulePath -Force
$modulePath = Join-Path $PSScriptRoot "modules\Computers.psm1"
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
# Declared global on purpose. Functions inside the .psm1 modules resolve
# unqualified commands in their module scope and then in the GLOBAL scope,
# never in this script's scope. Without "global:", every module-side call
# fails with CommandNotFoundException whenever the collector is launched as
# ".\Collect-ADData.ps1" from an open session rather than with -File --
# which is how it is actually launched in the field. That cost the entire
# Users section on AUSL Romagna (2026-08-06).
function global:Write-CollectorLog {
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
# Test-CollectorElevation
# Returns $true (elevated), $false (not elevated), or $null (undeterminable).
#
# Deliberate copy of Test-LMElevation (installer/modules/LegacyMCP.Common.psm1,
# same three lines, same API). The collector ships as a standalone artifact and
# must keep working when distributed without the installer modules, so it
# cannot import them. Two copies across two independent deliverables: if the
# check ever changes, both must change.
#
# Returns $null rather than throwing when the .NET security types are not
# available: a diagnostic hint must never abort a collection (P10). $null is
# distinct from $false, so "cannot tell" is never reported as "not elevated"
# -- note that in PowerShell ($null -eq $false) is False, which is what keeps
# the two branches apart.
# ---------------------------------------------------------------------------
function Test-CollectorElevation {
    try {
        $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        return [bool]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $null
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
# A lightweight Get-ADDomain call identifies the collection target (domain and
# its forest) before collection starts, so that OutputPath and LogPath can be
# resolved for the session header. The resolved forest name is then handed to
# the Forest and FSMO sections, so they cannot disagree with the metadata.
# ---------------------------------------------------------------------------
$startTime = Get-Date

$dcNameEarly = if ($Server) {
    $Server
} else {
    try { (Get-ADDomainController -Discover @commonParams).HostName } catch { "auto" }
}

# Resolve the collection TARGET -- both the domain and the forest it belongs to.
#
# Get-ADForest without -Identity binds to its "Current" parameter set, which
# returns the forest of the LocalComputer/LoggedOnUser and ignores -Server for
# the purpose of choosing WHICH forest to describe. In a cross-forest
# collection that is the wrong forest: the field JSON reported
# "auslromagna.it" (the caller) while collecting "ausl.fo.it" (the target).
#
# Get-ADDomain honours -Server and exposes .Forest, so the target forest is
# derived from the target domain instead of from the caller's identity.
#
# No fallback here by design (P4). The previous $env:COMPUTERNAME fallback was
# dead code: the collector runs on a member server or workstation (P11), never
# on a DC, so Get-ADDomain -Server <that machine> could never succeed. Failing
# explicitly beats naming the output file after the wrong domain.
$collectDomainEarly = $null
$collectForestEarly = $null
try {
    $targetDomain       = Get-ADDomain @commonParams
    $collectDomainEarly = $targetDomain.DNSRoot
    $collectForestEarly = $targetDomain.Forest
} catch {
    $targetDesc = if ($Server) { "-Server $Server" } else { "the caller's own domain (no -Server given)" }
    throw ("Unable to determine the collection target domain from $targetDesc : $_" +
           " -- cannot name the output file or the metadata reliably." +
           " Check -Server, connectivity to the DC, and the credentials in use.")
}

if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) `
        "$($collectDomainEarly)_ad-data.json"
}
$OutputPath     = [System.IO.Path]::GetFullPath($OutputPath)
$script:LogPath = [System.IO.Path]::ChangeExtension($OutputPath, ".log")

# ---------------------------------------------------------------------------
# Session header
# ---------------------------------------------------------------------------
$sep = "=" * 80
@(
    $sep,
    "LegacyMCP Collector v1.7.0 -- collection started",
    "Forest : $collectForestEarly",
    "Domain : $collectDomainEarly",
    "DC     : $dcNameEarly",
    "Output : $OutputPath",
    "Log    : $($script:LogPath)",
    "Start  : $(Get-Date $startTime -Format 'yyyy-MM-dd HH:mm:ss')",
    $sep
) | Out-File -FilePath $script:LogPath -Encoding UTF8

Write-CollectorLog -Level INFO -Section "Startup" -Message "Forest (of target domain): $collectForestEarly"
Write-CollectorLog -Level INFO -Section "Startup" -Message "Domain (target DC): $collectDomainEarly"

# ---------------------------------------------------------------------------
# Elevation pre-flight (task #137)
# Field-confirmed on two independent tools (this collector and Carl Webster's
# script): a non-elevated PowerShell session can prevent reading
# userAccountControl in some AD environments, even with adequate AD rights.
# The result is silent data loss, so warn up front instead of leaving the
# operator to discover it hours later from an aggregated warning in the log.
#
# Warning only, never blocking: the other sections are unaffected and a
# non-elevated collection is still useful.
#
# Emitted here, after $script:LogPath exists, so the warning reaches the log
# file as well as the console. The two-call pattern (Write-Host banner +
# Write-CollectorLog) matches the one already used for the output-file rename
# warning further down.
# ---------------------------------------------------------------------------
$isElevated = Test-CollectorElevation

if ($isElevated -eq $false) {
    $sepWarn = "-" * 80
    Write-Host ""
    Write-Host $sepWarn -ForegroundColor Yellow
    Write-Host "  [WARN] This PowerShell session is NOT elevated." -ForegroundColor Yellow
    Write-Host "         In some AD environments this prevents reading userAccountControl" -ForegroundColor Yellow
    Write-Host "         and the properties derived from it (Enabled, PasswordNeverExpires," -ForegroundColor Yellow
    Write-Host "         TrustedForDelegation...), causing silent data loss even when the" -ForegroundColor Yellow
    Write-Host "         account has adequate AD permissions." -ForegroundColor Yellow
    Write-Host "         If the collection reports many null values on those fields, re-run" -ForegroundColor Yellow
    Write-Host "         PowerShell as Administrator." -ForegroundColor Yellow
    Write-Host $sepWarn -ForegroundColor Yellow
    Write-Host ""
    Write-CollectorLog -Level WARN -Section "Startup" `
        -Message "Session NOT elevated -- userAccountControl and derived properties (Enabled, PasswordNeverExpires, TrustedForDelegation) may be unreadable in some AD environments. Re-run as Administrator if those fields come back null."
} elseif ($null -eq $isElevated) {
    Write-CollectorLog -Level WARN -Section "Startup" `
        -Message "Could not determine whether the session is elevated -- continuing. If userAccountControl comes back null, try re-running as Administrator."
} else {
    Write-CollectorLog -Level INFO -Section "Startup" -Message "Session elevated: yes"
}

$data = [ordered]@{}

# ---------------------------------------------------------------------------
# Data collection
# ---------------------------------------------------------------------------

# --- Forest ---
$data["forest"] = Invoke-Section "Forest" {
    Get-ForestData -CommonParams $commonParams -ForestName $collectForestEarly
}
if ($null -ne $data["forest"]) {
    Write-CollectorLog -Level INFO -Section "Forest" -Message "collected: $($data['forest'].Name)"
}

# --- Optional Features ---
$data["optional_features"] = Invoke-Section "Optional Features" {
    Get-OptionalFeaturesData -CommonParams $commonParams
}
if ($null -ne $data["optional_features"]) {
    Write-CollectorLog -Level INFO -Section "Optional Features" `
        -Message "collected: $(@($data['optional_features']).Count)"
}

# --- Schema Extensions ---
$data["schema"] = Invoke-Section "Schema Extensions" {
    Get-SchemaExtensionsData -CommonParams $commonParams
}
if ($null -ne $data["schema"]) {
    Write-CollectorLog -Level INFO -Section "Schema Extensions" `
        -Message "collected: $(@($data['schema']).Count) custom extensions"
}

# --- Schema Product Presence ---
$data["schema_products"] = Invoke-Section "Schema Products" {
    Get-SchemaProductPresenceData -CommonParams $commonParams
}
if ($null -ne $data["schema_products"]) {
    Write-CollectorLog -Level INFO -Section "Schema Products" -Message "collected"
}

# --- Domains ---
$data["domains"] = Invoke-Section "Domains" {
    Get-DomainData -CommonParams $commonParams
}
if ($null -ne $data["domains"]) {
    Write-CollectorLog -Level INFO -Section "Domains" -Message "collected"
}

# --- Default Password Policy ---
$data["default_password_policy"] = Invoke-Section "Default Password Policy" {
    Get-DefaultPasswordPolicyData -CommonParams $commonParams
}
if ($null -ne $data["default_password_policy"]) {
    Write-CollectorLog -Level INFO -Section "Default Password Policy" -Message "collected"
}

# --- Domain Controllers ---
$data["dcs"] = Invoke-Section "Domain Controllers" {
    Get-DCData -CommonParams $commonParams
}
if ($null -ne $data["dcs"]) {
    Write-CollectorLog -Level INFO -Section "Domain Controllers" `
        -Message "collected: $(@($data['dcs']).Count)"
}

# --- FSMO Roles ---
$data["fsmo_roles"] = Invoke-Section "FSMO Roles" {
    $fsmoForest = Get-FSMOForestData -CommonParams $commonParams -ForestName $collectForestEarly
    $fsmoDomain = Get-FSMODomainData -CommonParams $commonParams
    $fsmoForest + $fsmoDomain
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

# --- DC File Locations ---
$data["dc_file_locations"] = Invoke-Section "DC File Locations" {
    Get-DCFileLocationsData -CommonParams $commonParams
}
if ($null -ne $data["dc_file_locations"]) {
    Write-CollectorLog -Level INFO -Section "DC File Locations" `
        -Message "collected: $(@($data['dc_file_locations']).Count) DCs"
}

# --- DC Network Configuration ---
$data["dc_network_config"] = Invoke-Section "DC Network Config" {
    Get-DCNetworkConfigData -CommonParams $commonParams
}
if ($null -ne $data["dc_network_config"]) {
    Write-CollectorLog -Level INFO -Section "DC Network Config" `
        -Message "collected: $(@($data['dc_network_config']).Count) DCs"
}

# --- Sites ---
$data["sites"] = Invoke-Section "Sites" {
    Get-SitesData -CommonParams $commonParams
}
if ($null -ne $data["sites"]) {
    Write-CollectorLog -Level INFO -Section "Sites" `
        -Message "collected: $(@($data['sites']).Count)"
}

# --- Site Links ---
$data["site_links"] = Invoke-Section "Site Links" {
    Get-SiteLinksData -CommonParams $commonParams
}
if ($null -ne $data["site_links"]) {
    Write-CollectorLog -Level INFO -Section "Site Links" `
        -Message "collected: $(@($data['site_links']).Count)"
}

# --- Users ---
$data["users"] = Invoke-Section "Users" {
    Get-UsersData -CommonParams $commonParams
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
    Get-PrivilegedAccountsData -CommonParams $commonParams
}
if ($null -ne $data["privileged_accounts"]) {
    Write-CollectorLog -Level INFO -Section "Privileged Accounts" `
        -Message "collected: $(@($data['privileged_accounts']).Count)"
}

# --- Groups ---
$data["groups"] = Invoke-Section "Groups" {
    Get-GroupsData -CommonParams $commonParams
}
if ($null -ne $data["groups"]) {
    Write-CollectorLog -Level INFO -Section "Groups" `
        -Message "collected: $(@($data['groups']).Count)"
}

# --- Group Members (flat table -- one row per member per group) ---
$data["group_members"] = Invoke-Section "Group Members" {
    Get-GroupMembersData -CommonParams $commonParams
}
if ($null -ne $data["group_members"]) {
    Write-CollectorLog -Level INFO -Section "Group Members" `
        -Message "collected: $(@($data['group_members']).Count) entries"
}

# --- Privileged Groups (with members) ---
$data["privileged_groups"] = Invoke-Section "Privileged Groups" {
    Get-PrivilegedGroupsData -CommonParams $commonParams
}
if ($null -ne $data["privileged_groups"]) {
    Write-CollectorLog -Level INFO -Section "Privileged Groups" `
        -Message "collected: $(@($data['privileged_groups']).Count) groups"
}

# --- OUs ---
$data["ous"] = Invoke-Section "OUs" {
    Get-OUsData -CommonParams $commonParams
}
if ($null -ne $data["ous"]) {
    Write-CollectorLog -Level INFO -Section "OUs" `
        -Message "collected: $(@($data['ous']).Count)"
}

# --- GPO Inventory ---
$data["gpos"] = Invoke-Section "GPO Inventory" {
    Get-GPOData -CommonParams $commonParams
}
if ($null -ne $data["gpos"]) {
    Write-CollectorLog -Level INFO -Section "GPO Inventory" `
        -Message "collected: $(@($data['gpos']).Count)"
}

# --- GPO Links ---
$data["gpo_links"] = Invoke-Section "GPO Links" {
    Get-GPOLinksData -CommonParams $commonParams
}
if ($null -ne $data["gpo_links"]) {
    Write-CollectorLog -Level INFO -Section "GPO Links" `
        -Message "collected: $(@($data['gpo_links']).Count)"
}

# --- Blocked Inheritance ---
$data["blocked_inheritance"] = Invoke-Section "Blocked Inheritance" {
    Get-BlockedInheritanceData -CommonParams $commonParams
}
if ($null -ne $data["blocked_inheritance"]) {
    Write-CollectorLog -Level INFO -Section "Blocked Inheritance" `
        -Message "collected: $(@($data['blocked_inheritance']).Count)"
}

# --- Trusts ---
$data["trusts"] = Invoke-Section "Trusts" {
    Get-TrustsData -CommonParams $commonParams
}
if ($null -ne $data["trusts"]) {
    Write-CollectorLog -Level INFO -Section "Trusts" `
        -Message "collected: $(@($data['trusts']).Count)"
}

# --- Foreign Security Principals ---
$data["fsp"] = Invoke-Section "Foreign Security Principals" {
    Get-FSPData -CommonParams $commonParams
}
if ($null -ne $data["fsp"]) {
    Write-CollectorLog -Level INFO -Section "Foreign Security Principals" `
        -Message "collected: $(@($data['fsp']).Count) FSP(s)"
}

# --- Fine-Grained Password Policies ---
$data["fgpp"] = Invoke-Section "FGPP" {
    Get-FGPPData -CommonParams $commonParams
}
if ($null -ne $data["fgpp"]) {
    Write-CollectorLog -Level INFO -Section "FGPP" `
        -Message "collected: $(@($data['fgpp']).Count)"
}

# --- DNS ---
$data["dns"] = Invoke-Section "DNS Zones" {
    Get-DNSZonesData -CommonParams $commonParams
}
if ($null -ne $data["dns"]) {
    Write-CollectorLog -Level INFO -Section "DNS Zones" `
        -Message "collected: $(@($data['dns']).Count)"
}

# --- DNS Forwarders ---
$data["dns_forwarders"] = Invoke-Section "DNS Forwarders" {
    Get-DNSForwardersData -CommonParams $commonParams
}
if ($null -ne $data["dns_forwarders"]) {
    Write-CollectorLog -Level INFO -Section "DNS Forwarders" `
        -Message "collected: $(@($data['dns_forwarders']).Count) DCs"
}

# --- Computers ---
$data["computers"] = Invoke-Section "Computers" {
    Get-ComputersData -CommonParams $commonParams
}
if ($null -ne $data["computers"]) {
    $computersArr   = @($data["computers"])
    $enabledComp    = @($computersArr | Where-Object { $_.Enabled -eq $true }).Count
    $disabledComp   = $computersArr.Count - $enabledComp
    Write-CollectorLog -Level INFO -Section "Computers" `
        -Message "collected: $($computersArr.Count)  (enabled: $enabledComp, disabled: $disabledComp)"
}

# --- PKI / CA Discovery ---
$data["pki"] = @(Invoke-Section "PKI / CA Discovery" {
    Get-PKIData -CommonParams $commonParams
})
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
    # Both sources are now anchored to the target domain: the forest section
    # resolves via Get-ADDomain(.Forest) + Get-ADForest -Identity, and the
    # early value comes from the same place. They must agree.
    $forestName = if ($data["forest"] -and $data["forest"].Name) {
        $data["forest"].Name
    } else {
        $collectForestEarly
    }

    $metadata = [ordered]@{
        module             = "ad-core"
        version            = "1.0"
        forest             = $forestName
        domain             = $collectDomainEarly
        collected_at       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        collector_version  = "1.7.0"
        collected_by       = "$env:USERDOMAIN\$env:USERNAME"
        # true / false / null (undeterminable). Kept so that a collection with
        # many null userAccountControl values can still be explained months
        # later without guessing (task #137).
        elevated           = $isElevated
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
    "Collection completed -- $forestName",
    "Sections OK : $($script:sectionsOK)/$totalSections",
    "Warnings   : $($script:sectionsWarn)",
    "Errors     : $($script:sectionsError)",
    "End        : $(Get-Date $endTime -Format 'yyyy-MM-dd HH:mm:ss')  (duration: $durationStr)",
    $sep
) | Out-File -FilePath $script:LogPath -Encoding UTF8 -Append
