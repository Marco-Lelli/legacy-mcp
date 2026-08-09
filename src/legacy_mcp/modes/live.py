"""Live Mode connector — executes PowerShell on Domain Controllers via subprocess.

No elevation pre-flight here, deliberately (task #137)
------------------------------------------------------
The collector (Collect-ADData.ps1) warns when it runs in a non-elevated
PowerShell session, because a non-elevated interactive session can fail to
read userAccountControl in some AD environments, silently emptying Enabled
and the delegation flags.

That check is intentionally NOT mirrored here, and its absence is not an
oversight. Live Mode does not run as an interactive session that a human
could elevate: it runs as the MCP server process (a Windows service under a
gMSA or service account in Profile B), and the scripts below are then shipped
to the Domain Controller by _run_ps_on() and executed there under that
identity via Kerberos. What governs attribute visibility here is the AD
permissions granted to the service account (see docs/minimum-permissions.md),
not a local UAC elevation state -- there is no "Run as Administrator" for a
service to be told about, and no operator at a console to warn.

If userAccountControl comes back null in Live Mode, the cause is the service
account's directory permissions, not elevation. The aggregated warning in the
"users" section below reports that case on its own.
"""

from __future__ import annotations

import json
import re
import subprocess
from base64 import b64encode
from typing import Any, TYPE_CHECKING

if TYPE_CHECKING:
    from legacy_mcp.workspace.workspace import ForestConfig

from legacy_mcp.eventlog import writer as eventlog


# RFC 1123 hostname/FQDN: letters, digits, hyphens, dots. No other
# characters are valid in a DNS name, and none of them are needed to
# reach a Domain Controller by hostname.
_FQDN_PATTERN = re.compile(r"^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,62}(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,62})?)*)?$")


def _validate_dc_fqdn(dc_fqdn: str) -> None:
    """Validate dc_fqdn before it is interpolated into a PowerShell command.

    Raises ValueError if dc_fqdn is not a plausible RFC 1123 hostname/FQDN.
    Defense in depth (P6, P9): dc_fqdn originates from config.yaml, which
    is normally trusted, but is validated here regardless before it
    reaches a subprocess command string.
    """
    if not dc_fqdn or len(dc_fqdn) > 253:
        raise ValueError(f"Invalid DC hostname: '{dc_fqdn}'")
    if not _FQDN_PATTERN.match(dc_fqdn):
        raise ValueError(
            f"Invalid DC hostname '{dc_fqdn}': must be a valid FQDN "
            f"(letters, digits, hyphens, dots only)"
        )


# ---------------------------------------------------------------------------
# Shared PowerShell membership helpers (task #134)
# ---------------------------------------------------------------------------
# Mirror of collector/modules/Membership.psm1, kept aligned with it (P2).
#
# Each entry in _SCRIPTS is executed as a self-contained script block via
# Invoke-Command, so there is no session-level place to import a module into.
# Defining the helpers once as this Python constant and prepending it to the
# three sections that need them keeps a single copy of the algorithm here,
# instead of three inline duplicates (P8).
#
# Differences from the collector module, both intentional:
#   - no @CommonParams splatting: these scripts already execute ON the DC
#   - Write-Warning instead of Write-CollectorLog, which does not exist here
# The well-known privileged groups whose membership is expanded. Single
# Live-Mode-side source, interpolated into every section that needs it, so the
# list cannot drift between sections. The collector keeps its own single copy
# in Membership.psm1 (Get-PrivilegedGroupNames): the scripts here are strings
# executed on the DC and cannot import a PowerShell module, so two sources
# total -- one per mode -- is the floor.
_PS_PRIVILEGED_GROUPS = (
    "$privilegedGroupNames = @('Domain Admins','Enterprise Admins','Schema Admins',"
    "'Administrators','Account Operators','Backup Operators',"
    "'Print Operators','Server Operators')\n"
)

# ---------------------------------------------------------------------------
# Target domain / forest resolution (P2 alignment with the collector fix)
# ---------------------------------------------------------------------------
# Get-ADDomain and Get-ADForest both default to their "Current" parameter set
# when called bare. That set resolves to the LocalComputer/LoggedOnUser
# identity, NOT to the directory being queried -- the same defect fixed in the
# collector (Collect-ADData.ps1 / Forest.psm1). Left bare, a cross-forest
# collection describes the CALLER's forest while collecting the target's data.
#
# The fix is NOT the collector's one transposed literally. The collector runs
# on the consultant's machine and anchors the lookup with -Server <target DC>.
# Live Mode is architecturally different: every script here is shipped to the
# DC by _run_ps_on() via "Invoke-Command -ComputerName <DC>", so it executes
# ON the target DC itself. There is no -Server to pass -- the server IS the
# executing machine. "-Current LocalComputer" is therefore the correct anchor
# here, and it is exact by construction rather than by convention.
#
# Verified: all seven sections that need this run through run_ps() or
# collect_dc_inventory(), never through run_ps_local() -- so "LocalComputer"
# is always a Domain Controller of the target domain, never the MCP host.
#
# Resolved once, in one place, and prepended to every section that needs it:
# seven independent lookups would be seven chances to drift apart again.
_PS_TARGET_RESOLUTION = (
    "function Get-TargetDomain {\n"
    "  return Get-ADDomain -Current LocalComputer\n"
    "}\n"
    # Same chain as the collector: target domain -> .Forest -> -Identity.
    # -Identity is what keeps Get-ADForest off its "Current" parameter set.
    "function Get-TargetForest {\n"
    "  $d = Get-TargetDomain\n"
    "  return Get-ADForest -Identity $d.Forest\n"
    "}\n"
    # Get-ADDefaultDomainPasswordPolicy has the same two parameter sets as
    # Get-ADDomain: bare, it binds to "Current" and resolves to the logged-on
    # user's domain (its own documented Example 5 says exactly that), so in a
    # cross-forest collection it would return the CALLER's password policy.
    # Lower impact than the forest/domain fields, identical mechanism.
    "function Get-TargetPasswordPolicy {\n"
    "  return Get-ADDefaultDomainPasswordPolicy -Current LocalComputer\n"
    "}\n"
)

_PS_MEMBERSHIP_HELPERS = (
    "function Get-SafePropertyValues {\n"
    "  param($InputObject, [string]$Name)\n"
    "  $values = @()\n"
    "  $prop = $InputObject.PSObject.Properties[$Name]\n"
    "  if ($prop -and $null -ne $prop.Value) { $values = @($prop.Value) }\n"
    "  return ,$values\n"
    "}\n"
    # Match on the type NAME, not the type itself: no hard dependency on the
    # AD assembly being loadable, and it still works under test doubles.
    "function Test-ADObjectNotFound {\n"
    "  param($ErrorRecord)\n"
    "  $typeName = ''\n"
    "  if ($ErrorRecord.Exception) { $typeName = $ErrorRecord.Exception.GetType().FullName }\n"
    "  if ($typeName -like '*IdentityNotFound*') { return $true }\n"
    "  if ($typeName -like '*ObjectNotFound*')   { return $true }\n"
    "  if ($ErrorRecord.CategoryInfo -and $ErrorRecord.CategoryInfo.Category -eq 'ObjectNotFound') { return $true }\n"
    "  return $false\n"
    "}\n"
    # Raw 'member' read: not subject to the ADWS MaxGroupOrMemberEntries cap
    # (default 5000) that makes Get-ADGroupMember fail with "The size limit
    # for this request was exceeded". Ranging is handled by the AD module.
    "function Get-RawGroupMemberDNs {\n"
    "  param([string]$GroupDN)\n"
    "  $obj = Get-ADObject -Identity $GroupDN -Properties member\n"
    "  $dns = Get-SafePropertyValues -InputObject $obj -Name 'member'\n"
    # Truncation sentinel (P4), same as the collector. Ranging is handled by
    # the AD module and was verified in the field, so this is not expected to
    # fire -- but a count landing exactly on a known LDAP policy boundary is
    # worth one line rather than a silent assumption. A group of exactly that
    # size is a harmless false positive.
    "  if ($dns.Count -eq 1000 -or $dns.Count -eq 1500 -or $dns.Count -eq 5000) {\n"
    "    Write-Warning \"Membership of '$GroupDN' = $($dns.Count) members, exactly on a known LDAP boundary -- verify it is not truncated\"\n"
    "  }\n"
    "  return ,$dns\n"
    "}\n"
    # Returns $null for an unresolvable DN (orphaned SID, tombstoned object,
    # foreign principal); any other error propagates to the caller (P4).
    "function Resolve-ADMemberByDN {\n"
    "  param([string]$DN)\n"
    "  try { $obj = Get-ADObject -Identity $DN -Properties objectClass,name,sAMAccountName }\n"
    "  catch { if (Test-ADObjectNotFound -ErrorRecord $_) { return $null } ; throw }\n"
    "  if ($null -eq $obj) { return $null }\n"
    "  $oc = ''\n"
    "  $ocv = Get-SafePropertyValues -InputObject $obj -Name 'objectClass'\n"
    "  if ($ocv.Count -gt 0) { $oc = [string]$ocv[-1] }\n"
    "  $nm = ''\n"
    "  $nmv = Get-SafePropertyValues -InputObject $obj -Name 'name'\n"
    "  if ($nmv.Count -gt 0) { $nm = [string]$nmv[0] }\n"
    "  $sam = $null\n"
    "  $samv = Get-SafePropertyValues -InputObject $obj -Name 'sAMAccountName'\n"
    "  if ($samv.Count -gt 0) { $sam = [string]$samv[0] }\n"
    "  $en = $null\n"
    "  if ($oc -eq 'user') {\n"
    "    try { $en = (Get-ADUser -Identity $DN -Properties Enabled).Enabled }\n"
    "    catch { if (-not (Test-ADObjectNotFound -ErrorRecord $_)) { throw } }\n"
    "  } elseif ($oc -eq 'computer') {\n"
    "    try { $en = (Get-ADComputer -Identity $DN -Properties Enabled).Enabled }\n"
    "    catch { if (-not (Test-ADObjectNotFound -ErrorRecord $_)) { throw } }\n"
    "  }\n"
    "  return [PSCustomObject]@{ DistinguishedName = $DN; SamAccountName = $sam;\n"
    "    Name = $nm; ObjectClass = $oc; Enabled = $en }\n"
    "}\n"
    # $Visited / $Collected / $Unresolved are mutated in place, so the cycle
    # guard and both de-duplications span the whole descent. The raw DN of an
    # unresolvable member is kept, not just counted: the caller turns it into
    # an explicit placeholder.
    "function Expand-ADGroupMembership {\n"
    "  param([string]$GroupDN, [hashtable]$Visited, $Collected, $Unresolved, [hashtable]$Counters)\n"
    "  if ($Visited.ContainsKey($GroupDN)) { $Counters['Cycles']++; return }\n"
    "  $Visited[$GroupDN] = $true\n"
    "  foreach ($dn in (Get-RawGroupMemberDNs -GroupDN $GroupDN)) {\n"
    "    $m = Resolve-ADMemberByDN -DN $dn\n"
    "    if ($null -eq $m) {\n"
    "      if (-not $Unresolved.Contains($dn)) { $Unresolved[$dn] = $true }\n"
    "      continue\n"
    "    }\n"
    "    if ($m.ObjectClass -eq 'group') {\n"
    "      Expand-ADGroupMembership -GroupDN $m.DistinguishedName -Visited $Visited"
    " -Collected $Collected -Unresolved $Unresolved -Counters $Counters\n"
    "    } elseif (-not $Collected.Contains($m.DistinguishedName)) {\n"
    "      $Collected[$m.DistinguishedName] = $m\n"
    "    }\n"
    "  }\n"
    "}\n"
    # Returns an object, not a bare array: the previous ",@(...)" contract made
    # @(Get-GroupMembersRecursive ...).Count silently return 1. Properties
    # cannot unroll through the pipeline.
    "function Get-GroupMembersRecursive {\n"
    "  param([string]$GroupDN)\n"
    "  $visited = @{}\n"
    "  $collected = [ordered]@{}\n"
    "  $unresolved = [ordered]@{}\n"
    "  $counters = @{ Cycles = 0 }\n"
    "  Expand-ADGroupMembership -GroupDN $GroupDN -Visited $visited"
    " -Collected $collected -Unresolved $unresolved -Counters $counters\n"
    "  return [PSCustomObject]@{ Resolved = @($collected.Values);"
    " Unresolved = @($unresolved.Keys); Cycles = $counters['Cycles'] }\n"
    "}\n"
)


# ---------------------------------------------------------------------------
# PowerShell script library
# ---------------------------------------------------------------------------
# Keyed by section name (matches KNOWN_SECTIONS in storage/loader.py).
# Sections not listed here are not yet implemented for Live Mode.

_SCRIPTS: dict[str, str] = {
    # ------------------------------------------------------------------
    # forest — adds GlobalCatalogs (collection join) and SchemaVersion
    # (requires separate RootDSE lookup; not available on Get-ADForest).
    # ------------------------------------------------------------------
    "forest": (
        _PS_TARGET_RESOLUTION +
        "$forest = Get-TargetForest\n"
        "$rootDSE = Get-ADRootDSE\n"
        "$schemaVersion = (Get-ADObject $rootDSE.schemaNamingContext"
        " -Properties objectVersion).objectVersion\n"
        "$configNC = $rootDSE.configurationNamingContext\n"
        "$dsSvcDN = 'CN=Directory Service,CN=Windows NT,CN=Services,' + $configNC\n"
        "$tombstone = $null\n"
        "try {\n"
        "  $dsObj = Get-ADObject $dsSvcDN -Properties tombstoneLifetime\n"
        "  $tombstone = if ($null -ne $dsObj.tombstoneLifetime -and"
        " $dsObj.tombstoneLifetime -gt 0) { [int]$dsObj.tombstoneLifetime } else { 180 }\n"
        "} catch { $tombstone = $null }\n"
        "[PSCustomObject]@{\n"
        "  Name                  = $forest.Name\n"
        "  ForestMode            = $forest.ForestMode.ToString()\n"
        "  SchemaMaster          = $forest.SchemaMaster\n"
        "  DomainNamingMaster    = $forest.DomainNamingMaster\n"
        "  Sites                 = $forest.Sites -join ', '\n"
        "  Domains               = $forest.Domains -join ', '\n"
        "  GlobalCatalogs        = $forest.GlobalCatalogs -join ', '\n"
        "  SchemaVersion         = $schemaVersion\n"
        "  SPNSuffixes           = $forest.SPNSuffixes -join ', '\n"
        "  UPNSuffixes           = $forest.UPNSuffixes -join ', '\n"
        "  ApplicationPartitions = $forest.ApplicationPartitions -join ', '\n"
        "  TombstoneLifetime     = $tombstone\n"
        "} | ConvertTo-Json -Depth 5"
    ),
    # ------------------------------------------------------------------
    # domains — adds ChildDomains (joined) and Forest.
    # ------------------------------------------------------------------
    "domains": (
        _PS_TARGET_RESOLUTION +
        "$domain = Get-TargetDomain\n"
        "$rootDSE = Get-ADRootDSE\n"
        "$domainObj = Get-ADObject $rootDSE.defaultNamingContext"
        " -Properties 'ms-DS-MachineAccountQuota'\n"
        "$maq = $domainObj.'ms-DS-MachineAccountQuota'\n"
        "[PSCustomObject]@{\n"
        "  Name                 = $domain.Name\n"
        "  DNSRoot              = $domain.DNSRoot\n"
        "  NetBIOSName          = $domain.NetBIOSName\n"
        "  DomainSID            = $domain.DomainSID.Value\n"
        "  DomainMode           = $domain.DomainMode.ToString()\n"
        "  PDCEmulator          = $domain.PDCEmulator\n"
        "  RIDMaster            = $domain.RIDMaster\n"
        "  InfrastructureMaster = $domain.InfrastructureMaster\n"
        "  ChildDomains         = $domain.ChildDomains -join ', '\n"
        "  Forest               = $domain.Forest\n"
        "  AllowedDNSSuffixes   = $domain.AllowedDNSSuffixes -join ', '\n"
        "  MachineAccountQuota  = $maq\n"
        "} | ConvertTo-Json -Depth 5"
    ),
    # ------------------------------------------------------------------
    # dcs — adds Site, OperatingSystemVersion, Enabled, Reachable.
    # Test-Connection issues one ICMP ping per DC (same as collector).
    # ------------------------------------------------------------------
    "dcs": (
        # Materialized before the loop: the body does a network round-trip per
        # DC (Test-Connection), so streaming Get-ADDomainController straight
        # into it holds the ADWS enumeration cursor open for the whole run.
        # Past MaxEnumContextExpiration (default 30 min) the server drops it
        # with "invalid enumeration context". Same fix already applied to
        # DomainControllers.psm1 in the collector.
        "$allDCs = @(Get-ADDomainController -Filter *)\n"
        "$allDCs | ForEach-Object {\n"
        "  $dc = $_\n"
        "  $isServerCore = $null\n"
        "  try {\n"
        "    $installType = (Get-ItemProperty"
        " 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion'"
        " -ErrorAction SilentlyContinue).InstallationType\n"
        "    $isServerCore = ($installType -eq 'Server Core')\n"
        "  } catch { $isServerCore = $null }\n"
        "  [PSCustomObject]@{\n"
        "    Name                   = $dc.Name\n"
        "    HostName               = $dc.HostName\n"
        "    IPv4Address            = $dc.IPv4Address\n"
        "    Site                   = $dc.Site\n"
        "    OperatingSystem        = $dc.OperatingSystem\n"
        "    OperatingSystemVersion = $dc.OperatingSystemVersion\n"
        "    IsGlobalCatalog        = $dc.IsGlobalCatalog\n"
        "    IsReadOnly             = $dc.IsReadOnly\n"
        "    Enabled                = $dc.Enabled\n"
        "    Reachable              = (Test-Connection $dc.HostName -Count 1 -Quiet)\n"
        "    LdapPort               = 389\n"
        "    SslPort                = 636\n"
        "    OperationMasterRoles   = ($dc.OperationMasterRoles -join ', ')\n"
        "    IsServerCore           = $isServerCore\n"
        "  }\n"
        "} | ConvertTo-Json -Depth 5"
    ),
    # ------------------------------------------------------------------
    # users — adds 11 fields. No cap: full inventory, every call
    # (Principle 4 — no implicit, silent truncation). Pagination for MCP
    # callers is handled downstream by the get_users tool (limit/offset).
    # ------------------------------------------------------------------
    "users": (
        "$cannotChangePasswordNullCount = 0\n"
        "$uacNullCount = 0\n"
        "$results = Get-ADUser -Filter * -Properties Enabled,PasswordNeverExpires,LockedOut,"
        "LastLogonDate,PasswordLastSet,Description,mail,adminCount,SIDHistory,"
        "TrustedForDelegation,TrustedToAuthForDelegation,'msDS-AllowedToDelegateTo',"
        "userAccountControl,homeDirectory,homeDrive,primaryGroupID,CannotChangePassword |\n"
        "  ForEach-Object {\n"
        # Derived from userAccountControl bits, not from the constructed property --
        # returns $null on most objects when userAccountControl is also requested
        # explicitly in a mass Get-ADUser -Filter * pull (task #131, field-confirmed
        # on AUSL Romagna, 11105 users). If userAccountControl itself is $null (seen
        # structurally on a whole domain in a later field test, cause not yet
        # determined -- see task #133), the 4 derived fields stay $null explicitly
        # instead of defaulting to a plausible-looking but fabricated boolean.
        "    if ($_.userAccountControl -ne $null) {\n"
        "      $uac = [int]$_.userAccountControl\n"
        "      $enabled = (-not [bool]($uac -band 0x2))\n"
        "      $passwordNeverExpires = [bool]($uac -band 0x10000)\n"
        "      $trustedForDelegation = [bool]($uac -band 0x80000)\n"
        "      $trustedToAuthForDelegation = [bool]($uac -band 0x1000000)\n"
        "    } else {\n"
        "      $uacNullCount++\n"
        "      $enabled = $null\n"
        "      $passwordNeverExpires = $null\n"
        "      $trustedForDelegation = $null\n"
        "      $trustedToAuthForDelegation = $null\n"
        "    }\n"
        "    [PSCustomObject]@{\n"
        "      SamAccountName             = $_.SamAccountName\n"
        "      DisplayName                = $_.DisplayName\n"
        "      UserPrincipalName          = $_.UserPrincipalName\n"
        "      DistinguishedName          = $_.DistinguishedName\n"
        "      Mail                       = $_.mail\n"
        "      Enabled                    = $enabled\n"
        "      PasswordNeverExpires       = $passwordNeverExpires\n"
        "      LockedOut                  = $_.LockedOut\n"
        "      LastLogonDate              = $_.LastLogonDate\n"
        "      PasswordLastSet            = $_.PasswordLastSet\n"
        "      Description                = $_.Description\n"
        "      AdminCount                 = $_.adminCount\n"
        "      SIDHistory                 = @($_.SIDHistory | ForEach-Object { $_.Value })\n"
        "      TrustedForDelegation       = $trustedForDelegation\n"
        "      TrustedToAuthForDelegation = $trustedToAuthForDelegation\n"
        "      AllowedToDelegateTo        = ($_.'msDS-AllowedToDelegateTo') -join ', '\n"
        "      PasswordNotRequired        = [bool]($_.userAccountControl -band 0x20)\n"
        "      HomeDrive                  = $_.homeDrive\n"
        "      HomeDirectory              = $_.homeDirectory\n"
        "      PrimaryGroupID             = $_.primaryGroupID\n"
        "      CannotChangePassword       = if ($_.CannotChangePassword -ne $null) { [bool]$_.CannotChangePassword } else {\n"
        "        $cannotChangePasswordNullCount++\n"
        "        $false\n"
        "      }\n"
        "    }\n"
        "  }\n"
        # Single aggregated warning after the full pipeline, not one per user --
        # avoids thousands of synchronous writes on environments where the field
        # is null at scale (same failure mode as CannotChangePassword itself).
        "if ($cannotChangePasswordNullCount -gt 0) {\n"
        "  Write-Warning \"CannotChangePassword was null for $cannotChangePasswordNullCount users out of $(@($results).Count) collected - fallback to false applied for all - see task #133\"\n"
        "}\n"
        "if ($uacNullCount -gt 0) {\n"
        "  Write-Warning \"userAccountControl not available for $uacNullCount users out of $(@($results).Count) collected - Enabled/PasswordNeverExpires/TrustedForDelegation/TrustedToAuthForDelegation set to null for these users, not calculable - cause to be investigated separately (permissions/DC)\"\n"
        "}\n"
        "@($results) | ConvertTo-Json -Depth 3"
    ),
    # ------------------------------------------------------------------
    # groups — adds SamAccountName, DistinguishedName, AdminCount.
    # MemberCount is the length of the raw 'member' attribute: Get-ADGroupMember
    # was capped by the ADWS MaxGroupOrMemberEntries limit (default 5000) and
    # returned -1 for every group above it (task #134). -1 still means a real
    # retrieval failure, not an empty group.
    # ------------------------------------------------------------------
    "groups": (
        _PS_MEMBERSHIP_HELPERS +
        # Materialized before the loop: streaming Get-ADGroup into a slow
        # ForEach-Object holds the ADWS enumeration cursor open past
        # MaxEnumContextExpiration (default 30 min) and the server drops it
        # with "invalid enumeration context". Same fix as the collector.
        "$allGroups = @(Get-ADGroup -Filter * -Properties adminCount)\n"
        "$allGroups | ForEach-Object {\n"
        "  $count = try {\n"
        # Assign then count: Get-RawGroupMemberDNs returns ",$dns" to keep the
        # array intact, so wrapping the call in @() would always count 1.
        "    $memberDNs = Get-RawGroupMemberDNs -GroupDN $_.DistinguishedName\n"
        "    $memberDNs.Count\n"
        "  } catch { -1 }\n"
        "  [PSCustomObject]@{\n"
        "    Name              = $_.Name\n"
        "    SamAccountName    = $_.SamAccountName\n"
        "    DistinguishedName = $_.DistinguishedName\n"
        "    GroupCategory     = $_.GroupCategory.ToString()\n"
        "    GroupScope        = $_.GroupScope.ToString()\n"
        "    MemberCount       = $count\n"
        "    AdminCount        = $_.adminCount\n"
        "  }\n"
        "} | ConvertTo-Json -Depth 3"
    ),
    # ------------------------------------------------------------------
    # ous — adds BlockedInheritance (gPOptions bitmask) and LinkedGPOs.
    # ------------------------------------------------------------------
    "ous": (
        "Get-ADOrganizationalUnit -Filter * -Properties gpLink,gPOptions | ForEach-Object {\n"
        "  [PSCustomObject]@{\n"
        "    Name               = $_.Name\n"
        "    DistinguishedName  = $_.DistinguishedName\n"
        "    BlockedInheritance = ($_.gPOptions -band 1) -eq 1\n"
        "    LinkedGPOs         = $_.gpLink\n"
        "  }\n"
        "} | ConvertTo-Json -Depth 3"
    ),
    # ------------------------------------------------------------------
    # gpos — adds CreationTime, ModificationTime, Owner.
    # Wrapped in try/catch: GPO cmdlets require GPMC / RSAT.
    # ------------------------------------------------------------------
    "gpos": (
        "try {\n"
        "  Get-GPO -All | ForEach-Object {\n"
        "    [PSCustomObject]@{\n"
        "      DisplayName      = $_.DisplayName\n"
        "      Id               = $_.Id.ToString()\n"
        "      GpoStatus        = $_.GpoStatus.ToString()\n"
        "      CreationTime     = $_.CreationTime\n"
        "      ModificationTime = $_.ModificationTime\n"
        "      Owner            = $_.Owner\n"
        "    }\n"
        "  } | ConvertTo-Json -Depth 3\n"
        "} catch { '[]' }"
    ),
    # ------------------------------------------------------------------
    # sites — adds Subnets via per-site Get-ADReplicationSubnet lookup.
    # ------------------------------------------------------------------
    "sites": (
        # Materialized before the loop: the body issues a secondary AD query
        # per site (Get-ADReplicationSubnet). Site counts are small in
        # practice, so this is preventive rather than a live risk -- but it is
        # the same known pattern, and a known mine is not worth leaving armed.
        "$allSites = @(Get-ADReplicationSite -Filter *)\n"
        "$allSites | ForEach-Object {\n"
        "  $subnets = try {\n"
        "    (Get-ADReplicationSubnet -Filter \"Site -eq '$($_.DistinguishedName)'\").Name"
        " -join ', '\n"
        "  } catch { '' }\n"
        "  [PSCustomObject]@{\n"
        "    Name        = $_.Name\n"
        "    Description = $_.Description\n"
        "    Subnets     = $subnets\n"
        "  }\n"
        "} | ConvertTo-Json -Depth 3"
    ),
    # ------------------------------------------------------------------
    # trusts — adds TrustAttributes, SIDFiltering flags, DisallowTransivity,
    # DistinguishedName.
    # ------------------------------------------------------------------
    "trusts": (
        "Get-ADTrust -Filter * | ForEach-Object {\n"
        "  [PSCustomObject]@{\n"
        "    Name                    = $_.Name\n"
        "    Direction               = $_.Direction.ToString()\n"
        "    TrustType               = $_.TrustType.ToString()\n"
        "    TrustAttributes         = $_.TrustAttributes\n"
        "    SelectiveAuthentication = $_.SelectiveAuthentication\n"
        "    SIDFilteringForestAware = $_.SIDFilteringForestAware\n"
        "    SIDFilteringQuarantined = $_.SIDFilteringQuarantined\n"
        "    DisallowTransivity      = $_.DisallowTransivity\n"
        "    DistinguishedName       = $_.DistinguishedName\n"
        "  }\n"
        "} | ConvertTo-Json -Depth 3"
    ),
    # ------------------------------------------------------------------
    # fgpp — adds 8 fields; MaxPasswordAge/LockoutDuration converted to
    # int days/minutes to match collector output. AppliesTo resolved via
    # Get-ADFineGrainedPasswordPolicySubject (empty string on error).
    # ------------------------------------------------------------------
    "fgpp": (
        # Materialized before the loop, same reasoning as "sites": a secondary
        # AD query per policy (Get-ADFineGrainedPasswordPolicySubject).
        "$allPsos = @(Get-ADFineGrainedPasswordPolicy -Filter *)\n"
        "$allPsos | ForEach-Object {\n"
        "  $pso = $_\n"
        "  $appliesTo = try {\n"
        "    (Get-ADFineGrainedPasswordPolicySubject $pso).Name -join ', '\n"
        "  } catch { '' }\n"
        "  [PSCustomObject]@{\n"
        "    Name                        = $pso.Name\n"
        "    Precedence                  = $pso.Precedence\n"
        "    MinPasswordLength           = $pso.MinPasswordLength\n"
        "    PasswordHistoryCount        = $pso.PasswordHistoryCount\n"
        "    MaxPasswordAgeDays          = $pso.MaxPasswordAge.Days\n"
        "    MinPasswordAgeDays          = $pso.MinPasswordAge.Days\n"
        "    ComplexityEnabled           = $pso.ComplexityEnabled\n"
        "    ReversibleEncryptionEnabled = $pso.ReversibleEncryptionEnabled\n"
        "    LockoutThreshold            = $pso.LockoutThreshold\n"
        "    LockoutDurationMinutes      = $pso.LockoutDuration.Minutes\n"
        "    LockoutObservationMinutes   = $pso.LockoutObservationWindow.Minutes\n"
        "    AppliesTo                   = $appliesTo\n"
        "  }\n"
        "} | ConvertTo-Json -Depth 3"
    ),
    # ------------------------------------------------------------------
    # dns — adds ReplicationScope, IsReverseLookupZone, IsAutoCreated, DC.
    # Runs locally on the MCP server host via run_ps_local() — single hop to PDC.
    # Mirrors DNS.psm1 Get-DNSZonesData (Principle 2).
    # Requires DnsServer PS module (RSAT). Wrapped in try/catch.
    # ------------------------------------------------------------------
    "dns": (
        "try {\n"
        "  $dc = (Get-ADDomainController -Discover -Service PrimaryDC).HostName\n"
        "  Get-DnsServerZone -ComputerName $dc | ForEach-Object {\n"
        "    [PSCustomObject]@{\n"
        "      ZoneName            = $_.ZoneName\n"
        "      ZoneType            = $_.ZoneType.ToString()\n"
        "      IsDsIntegrated      = $_.IsDsIntegrated\n"
        "      ReplicationScope    = $_.ReplicationScope\n"
        "      IsReverseLookupZone = $_.IsReverseLookupZone\n"
        "      IsAutoCreated       = $_.IsAutoCreated\n"
        "      DC                  = $dc\n"
        "    }\n"
        "  } | ConvertTo-Json -Depth 3\n"
        "} catch { '[]' }"
    ),
    # ------------------------------------------------------------------
    # pki — uses RootDSE.configurationNamingContext (more reliable than
    # Get-ADDomain) and scopes to CN=Enrollment Services. Adds ObjectClass.
    # ------------------------------------------------------------------
    "pki": (
        "$configDN = (Get-ADRootDSE).configurationNamingContext\n"
        "$enrollmentDN = 'CN=Enrollment Services,CN=Public Key Services,"
        "CN=Services,' + $configDN\n"
        "try {\n"
        "  @(Get-ADObject -SearchBase $enrollmentDN -Filter * | ForEach-Object {\n"
        "    [PSCustomObject]@{\n"
        "      Name              = $_.Name\n"
        "      DistinguishedName = $_.DistinguishedName\n"
        "      ObjectClass       = $_.ObjectClass\n"
        "    }\n"
        "  }) | ConvertTo-Json -Depth 3\n"
        "} catch { '[]' }"
    ),
    # ------------------------------------------------------------------
    # optional_features — AD Optional Features (e.g. Recycle Bin).
    # ------------------------------------------------------------------
    "optional_features": (
        "Get-ADOptionalFeature -Filter * | ForEach-Object {\n"
        "  [PSCustomObject]@{\n"
        "    Name    = $_.Name\n"
        "    Enabled = $_.EnabledScopes.Count -gt 0\n"
        "    Scopes  = $_.EnabledScopes -join ', '\n"
        "  }\n"
        "} | ConvertTo-Json -Depth 3"
    ),
    # ------------------------------------------------------------------
    # fsmo_roles — forest-level and domain-level FSMO role holders.
    # Scalar section (single dict, not a list).
    # ------------------------------------------------------------------
    "fsmo_roles": (
        _PS_TARGET_RESOLUTION +
        "$forest = Get-TargetForest\n"
        "$domain = Get-TargetDomain\n"
        "[PSCustomObject]@{\n"
        "  SchemaMaster         = $forest.SchemaMaster\n"
        "  DomainNamingMaster   = $forest.DomainNamingMaster\n"
        "  PDCEmulator          = $domain.PDCEmulator\n"
        "  RIDMaster            = $domain.RIDMaster\n"
        "  InfrastructureMaster = $domain.InfrastructureMaster\n"
        "} | ConvertTo-Json -Depth 3"
    ),
    # ------------------------------------------------------------------
    # default_password_policy — domain default password / lockout settings.
    # Scalar section (single dict, not a list).
    # ------------------------------------------------------------------
    "default_password_policy": (
        _PS_TARGET_RESOLUTION +
        "$p = Get-TargetPasswordPolicy\n"
        "$domain = (Get-TargetDomain).DNSRoot\n"
        "[PSCustomObject]@{\n"
        "  Domain                      = $domain\n"
        "  MinPasswordLength           = $p.MinPasswordLength\n"
        "  PasswordHistoryCount        = $p.PasswordHistoryCount\n"
        "  MaxPasswordAge              = $p.MaxPasswordAge.Days\n"
        "  MinPasswordAge              = $p.MinPasswordAge.Days\n"
        "  ComplexityEnabled           = $p.ComplexityEnabled\n"
        "  ReversibleEncryptionEnabled = $p.ReversibleEncryptionEnabled\n"
        "  LockoutThreshold            = $p.LockoutThreshold\n"
        "  LockoutDuration             = $p.LockoutDuration.Minutes\n"
        "  LockoutObservationWindow    = $p.LockoutObservationWindow.Minutes\n"
        "} | ConvertTo-Json -Depth 3"
    ),
    # ------------------------------------------------------------------
    # sysvol — DFSR/FRS replication state for the local DC. Runs on each
    # DC via collect_dc_inventory(). Dual-mode: WMI DFSR, then LDAP
    # CN=DFSR-GlobalSettings, then NtFrs registry fallback (Principle 9).
    # ------------------------------------------------------------------
    "sysvol": (
        _PS_TARGET_RESOLUTION +
        "$dcFqdn = ($env:COMPUTERNAME + '.' + $env:USERDNSDOMAIN).ToLower()\n"
        "$SysvolStateMap = @{ 0='Uninitialized'; 1='Initialized'; 2='Initial Sync';"
        " 3='Auto Recovery'; 4='Normal'; 5='In Error' }\n"
        "try {\n"
        "  $dfsr = @(Get-WmiObject -Namespace 'root\\MicrosoftDFS'"
        " -Class DfsrReplicatedFolderInfo"
        " -Filter \"ReplicatedFolderName='SYSVOL Share'\" -ErrorAction Stop)\n"
        "  if ($dfsr.Count -gt 0) {\n"
        "    $stateInt = [int]$dfsr[0].State\n"
        "    $stateStr = if ($SysvolStateMap.ContainsKey($stateInt))"
        " { $SysvolStateMap[$stateInt] } else { \"Unknown ($stateInt)\" }\n"
        "    [PSCustomObject]@{ DC=$dcFqdn; Mechanism='DFSR'; State=$stateStr; Status='OK' }"
        " | ConvertTo-Json -Depth 3\n"
        "  } else {\n"
        "    $domainDN = (Get-TargetDomain).DistinguishedName\n"
        "    $dfsrGlobalDN = 'CN=DFSR-GlobalSettings,CN=System,' + $domainDN\n"
        "    $dfsrGlobal = $null\n"
        "    try {\n"
        "      $searcher = New-Object DirectoryServices.DirectorySearcher\n"
        "      $searcher.SearchRoot = New-Object DirectoryServices.DirectoryEntry("
        "'LDAP://' + $dfsrGlobalDN)\n"
        "      $searcher.SearchScope = 'Base'\n"
        "      $dfsrGlobal = $searcher.FindOne()\n"
        "    } catch [System.Runtime.InteropServices.COMException] {"
        " $dfsrGlobal = $null }\n"
        "    catch { $dfsrGlobal = $null }\n"
        "    if ($dfsrGlobal) {\n"
        "      $flags = $dfsrGlobal.Properties['msDFSR-Flags']\n"
        "      $flagInt = if ($flags -and $flags.Count -gt 0) { [int]$flags[0] } else { $null }\n"
        "      $DfsrMigrationStateMap = @{ 0='Start'; 16='Prepared'; 32='Redirected'; 48='Eliminated' }\n"
        "      $stateStr = if ($null -ne $flagInt -and $DfsrMigrationStateMap.ContainsKey($flagInt)) {\n"
        "        $DfsrMigrationStateMap[$flagInt]\n"
        "      } elseif ($null -ne $flagInt) {\n"
        "        \"Unknown ($flagInt)\"\n"
        "      } else { 'Not Configured' }\n"
        "      [PSCustomObject]@{ DC=$dcFqdn; Mechanism='DFSR'; State=$stateStr; Status='OK' }"
        " | ConvertTo-Json -Depth 3\n"
        "    } else {\n"
        "      $ntfrs = Get-ItemProperty"
        " 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\NtFrs'"
        " -ErrorAction SilentlyContinue\n"
        "      if ($ntfrs) {\n"
        "        [PSCustomObject]@{ DC=$dcFqdn; Mechanism='FRS';"
        " State=$null; Status='OK' } | ConvertTo-Json -Depth 3\n"
        "      } else {\n"
        "        [PSCustomObject]@{ DC=$dcFqdn; Mechanism='Unknown';"
        " State=$null; Status='OK' } | ConvertTo-Json -Depth 3\n"
        "      }\n"
        "    }\n"
        "  }\n"
        "} catch {\n"
        "  [PSCustomObject]@{ DC=$dcFqdn; Mechanism='Unknown';"
        " State='Unreachable'; Status='Unreachable' } | ConvertTo-Json -Depth 3\n"
        "}"
    ),
    # ------------------------------------------------------------------
    # site_links — AD replication site links topology.
    # ------------------------------------------------------------------
    "site_links": (
        "Get-ADReplicationSiteLink -Filter * | ForEach-Object {\n"
        "  [PSCustomObject]@{\n"
        "    Name                        = $_.Name\n"
        "    Cost                        = $_.Cost\n"
        "    ReplicationFrequencyMinutes = $_.ReplicationFrequencyInMinutes\n"
        "    Transport                   = $_.InterSiteTransportProtocol\n"
        "    SitesIncluded               = $_.SitesIncluded -join ', '\n"
        "  }\n"
        "} | ConvertTo-Json -Depth 3"
    ),
    # ------------------------------------------------------------------
    # privileged_accounts — unique users in privileged groups (recursive).
    # De-duplicated by SamAccountName across all groups.
    # ------------------------------------------------------------------
    "privileged_accounts": (
        _PS_MEMBERSHIP_HELPERS +
        _PS_PRIVILEGED_GROUPS +
        "$seen = @{}\n"
        "$groups = @($privilegedGroupNames)\n"
        "$unresolvable = 0\n"
        "$failed = @()\n"
        "$results = foreach ($g in $groups) {\n"
        "  try {\n"
        "    $groupObj = Get-ADGroup -Identity $g\n"
        "    $expansion = Get-GroupMembersRecursive -GroupDN $groupObj.DistinguishedName\n"
        "    $unresolvable += $expansion.Unresolved.Count\n"
        "    $expansion.Resolved |\n"
        "      Where-Object { $_.ObjectClass -eq 'user' } |\n"
        "      ForEach-Object {\n"
        "        if (-not $seen[$_.SamAccountName]) {\n"
        "          $seen[$_.SamAccountName] = $true\n"
        "          [PSCustomObject]@{ SamAccountName = $_.SamAccountName; Group = $g }\n"
        "        }\n"
        "      }\n"
        # Per-group warning naming the failed group AND the reason, as the
        # collector does. The aggregate below lists the names but not why each
        # one failed.
        "  } catch {\n"
        "    $failed += $g\n"
        "    Write-Warning \"Group '$g' not enumerated: $_\"\n"
        "  }\n"
        "}\n"
        # Previously "catch { }" -- an entire privileged group could vanish
        # with nothing anywhere to show the count was under-reported (P4).
        # No placeholder in THIS section by design: it feeds a count of
        # privileged accounts (the "total" of query_page in tools/users.py).
        # The unresolved DNs are visible as placeholders in privileged_groups
        # and group_members instead.
        "if ($unresolvable -gt 0) {\n"
        "  Write-Warning \"$unresolvable unresolvable members during the expansion of privileged groups -- excluded from this count to avoid skewing it, visible as placeholders in privileged_groups and group_members\"\n"
        "}\n"
        "if ($failed.Count -gt 0) {\n"
        "  Write-Warning \"Privileged groups NOT enumerated ($($failed.Count)/$($groups.Count)): $($failed -join ', ') -- the privileged account count is incomplete\"\n"
        "}\n"
        "if ($results) { @($results) | ConvertTo-Json -Depth 3 } else { '[]' }"
    ),
    # ------------------------------------------------------------------
    # privileged_groups — per-group membership list (recursive) for the
    # 8 built-in privileged groups.
    # ------------------------------------------------------------------
    "privileged_groups": (
        _PS_MEMBERSHIP_HELPERS +
        _PS_PRIVILEGED_GROUPS +
        "$names = @($privilegedGroupNames)\n"
        "$results = foreach ($name in $names) {\n"
        "  try {\n"
        "    $groupObj = Get-ADGroup -Identity $name\n"
        "    $expansion = Get-GroupMembersRecursive -GroupDN $groupObj.DistinguishedName\n"
        "    if ($expansion.Unresolved.Count -gt 0) {\n"
        "      Write-Warning \"Group '$name': $($expansion.Unresolved.Count) unresolvable members (orphaned SID / removed object / external principal) -- reported as objectClass='unresolved' placeholders, the other members were collected\"\n"
        "    }\n"
        # Field casing is part of the JSON contract -- keep it as-is.
        "    $members = @($expansion.Resolved | ForEach-Object {\n"
        "      [PSCustomObject]@{ SamAccountName = $_.SamAccountName;\n"
        "        objectClass = $_.ObjectClass; distinguishedName = $_.DistinguishedName }\n"
        "    })\n"
        # Placeholder per unresolved DN, same three keys. This is the only
        # place where "this broken DN sits inside <privileged group>" survives.
        "    $members += @($expansion.Unresolved | ForEach-Object {\n"
        "      [PSCustomObject]@{ SamAccountName = $null;\n"
        "        objectClass = 'unresolved'; distinguishedName = $_ }\n"
        "    })\n"
        "    [PSCustomObject]@{ Group = $name; Members = @($members) }\n"
        "  } catch {\n"
        # Error was present in the collector but had been lost here -- P2 drift
        # found in the task #134 diagnostic, restored in the same pass.
        "    Write-Warning \"Group '$name' not collected: $_\"\n"
        "    [PSCustomObject]@{ Group = $name; Members = @(); Error = $_.ToString() }\n"
        "  }\n"
        "}\n"
        "@($results) | ConvertTo-Json -Depth 5"
    ),
    # ------------------------------------------------------------------
    # group_members — flat member list across ALL groups. Resolves
    # Enabled for user and computer members via individual AD lookups.
    # ------------------------------------------------------------------
    "group_members": (
        _PS_MEMBERSHIP_HELPERS +
        "$unresolvableTotal = 0\n"
        "$groupsWithUnresolvable = 0\n"
        "$groupsFailed = 0\n"
        # Materialized before the loop -- the per-member resolution is far too
        # slow to run under an open ADWS enumeration cursor (see "groups").
        "$allGroups = @(Get-ADGroup -Filter *)\n"
        "$results = $allGroups | ForEach-Object {\n"
        "  $groupName = $_.Name\n"
        "  $groupDN   = $_.DistinguishedName\n"
        "  try {\n"
        "    $unresolvableHere = 0\n"
        "    foreach ($dn in (Get-RawGroupMemberDNs -GroupDN $groupDN)) {\n"
        "      $m = Resolve-ADMemberByDN -DN $dn\n"
        # Placeholder instead of dropping the row: the raw DN identifies the
        # broken reference to clean up, and it keeps rows == MemberCount.
        # Existing keys only -- no new column for the loader to discard.
        "      if ($null -eq $m) {\n"
        "        $unresolvableHere++\n"
        "        [PSCustomObject]@{\n"
        "          GroupName               = $groupName\n"
        "          MemberSamAccountName    = $null\n"
        "          MemberDisplayName       = $null\n"
        "          MemberObjectClass       = 'unresolved'\n"
        "          MemberDistinguishedName = $dn\n"
        "          MemberEnabled           = $null\n"
        "        }\n"
        "        continue\n"
        "      }\n"
        "      [PSCustomObject]@{\n"
        "        GroupName               = $groupName\n"
        "        MemberSamAccountName    = $m.SamAccountName\n"
        "        MemberDisplayName       = $m.Name\n"
        "        MemberObjectClass       = $m.ObjectClass\n"
        "        MemberDistinguishedName = $m.DistinguishedName\n"
        "        MemberEnabled           = $m.Enabled\n"
        "      }\n"
        "    }\n"
        "    if ($unresolvableHere -gt 0) {\n"
        "      $unresolvableTotal += $unresolvableHere\n"
        "      $groupsWithUnresolvable++\n"
        "    }\n"
        # Per-group warning naming the failed group, as the collector does:
        # an aggregate count alone gives no way to tell WHICH groups are
        # missing from the output.
        "  } catch {\n"
        "    $groupsFailed++\n"
        "    Write-Warning \"Group '$groupName' not enumerated: $_\"\n"
        "  }\n"
        "}\n"
        # Aggregated once, not one warning per member: on an environment where
        # this fires at scale, per-member warnings would flood the run.
        "if ($unresolvableTotal -gt 0) {\n"
        "  Write-Warning \"$unresolvableTotal unresolvable members across $groupsWithUnresolvable groups (orphaned SID / removed object / external principal) -- reported as placeholder rows with MemberObjectClass='unresolved' and the raw DN in MemberDistinguishedName\"\n"
        "}\n"
        "if ($groupsFailed -gt 0) {\n"
        "  Write-Warning \"$groupsFailed groups not enumerated due to a read error -- see the preceding WARN lines\"\n"
        "}\n"
        "if ($results) { @($results) | ConvertTo-Json -Depth 3 } else { '[]' }"
    ),
    # ------------------------------------------------------------------
    # gpo_links — GPO links on the domain root and all OUs. Requires
    # GPMC / GroupPolicy PS module (RSAT). Wrapped in try/catch.
    # ------------------------------------------------------------------
    "gpo_links": (
        _PS_TARGET_RESOLUTION +
        "try {\n"
        "  $domainDN = (Get-TargetDomain).DistinguishedName\n"
        "  $ouDNs = Get-ADOrganizationalUnit -Filter *"
        " | Select-Object -ExpandProperty DistinguishedName\n"
        "  $targets = @($domainDN) + @($ouDNs)\n"
        "  $results = $targets | ForEach-Object {\n"
        "    $target = $_\n"
        "    try {\n"
        "      Get-GPInheritance -Target $target |\n"
        "        Select-Object -ExpandProperty GpoLinks |\n"
        "        Select-Object DisplayName, GpoId, Enabled, Enforced, Target, Order\n"
        "    } catch { }\n"
        "  }\n"
        "  if ($results) { @($results) | ConvertTo-Json -Depth 3 } else { '[]' }\n"
        "} catch { '[]' }"
    ),
    # ------------------------------------------------------------------
    # blocked_inheritance — OUs with GPO inheritance blocked (gPOptions
    # bitmask bit 0 set). Complement to the ous section BlockedInheritance
    # field; provides a targeted flat list for quick security review.
    # ------------------------------------------------------------------
    "blocked_inheritance": (
        "$results = Get-ADOrganizationalUnit -Filter * -Properties gPOptions |\n"
        "  Where-Object { ($_.gPOptions -band 1) -eq 1 } |\n"
        "  ForEach-Object {\n"
        "    [PSCustomObject]@{\n"
        "      Name              = $_.Name\n"
        "      DistinguishedName = $_.DistinguishedName\n"
        "    }\n"
        "  }\n"
        "if ($results) { @($results) | ConvertTo-Json -Depth 3 } else { '[]' }"
    ),
    # ------------------------------------------------------------------
    # dns_forwarders — forwarder IPs and UseRootHint per DC.
    # Runs locally on the MCP server host via run_ps_local() — iterates all DCs,
    # single hop per DC. Mirrors DNS.psm1 Get-DNSForwardersData (Principle 2).
    # Requires DnsServer PS module (RSAT). Degrades per DC.
    # ------------------------------------------------------------------
    "dns_forwarders": (
        "try {\n"
        "  $dcs = Get-ADDomainController -Filter *"
        " | Select-Object -ExpandProperty HostName\n"
        "  $results = foreach ($dc in $dcs) {\n"
        "    try {\n"
        "      $fwd = Get-DnsServerForwarder -ComputerName $dc\n"
        "      [PSCustomObject]@{\n"
        "        DC          = $dc\n"
        "        Forwarders  = ($fwd.IPAddress |"
        " ForEach-Object { $_.IPAddressToString }) -join ', '\n"
        "        UseRootHint = $fwd.UseRootHint\n"
        "        Status      = 'OK'\n"
        "      }\n"
        "    } catch {\n"
        "      [PSCustomObject]@{ DC = $dc; Forwarders = $null;"
        " UseRootHint = $null; Status = 'Unreachable' }\n"
        "    }\n"
        "  }\n"
        "  @($results) | ConvertTo-Json -Depth 3\n"
        "} catch { '[]' }"
    ),
    # ------------------------------------------------------------------
    # computers — full computer inventory. No cap (Principle 4 — no
    # implicit, silent truncation). IsCNO/IsVCO derived from
    # ServicePrincipalNames / isCriticalSystemObject.
    # ------------------------------------------------------------------
    "computers": (
        "Get-ADComputer -Filter * -Properties OperatingSystem,OperatingSystemVersion,"
        "Enabled,LastLogonDate,PasswordLastSet,Description,"
        "ServicePrincipalNames,isCriticalSystemObject,"
        "TrustedForDelegation,TrustedToAuthForDelegation,'msDS-AllowedToDelegateTo' |\n"
        "  ForEach-Object {\n"
        "    $isCNO = [bool]($_.ServicePrincipalNames -like '*MSClusterVirtualServer*')\n"
        "    $isVCO = [bool]((-not $isCNO) -and $_.isCriticalSystemObject)\n"
        "    [PSCustomObject]@{\n"
        "      Name                       = $_.Name\n"
        "      DistinguishedName          = $_.DistinguishedName\n"
        "      OperatingSystem            = $_.OperatingSystem\n"
        "      OperatingSystemVersion     = $_.OperatingSystemVersion\n"
        "      Enabled                    = $_.Enabled\n"
        "      LastLogonDate              = $_.LastLogonDate\n"
        "      PasswordLastSet            = $_.PasswordLastSet\n"
        "      Description                = $_.Description\n"
        "      IsCNO                      = $isCNO\n"
        "      IsVCO                      = $isVCO\n"
        "      TrustedForDelegation       = $_.TrustedForDelegation\n"
        "      TrustedToAuthForDelegation = $_.TrustedToAuthForDelegation\n"
        "      AllowedToDelegateTo        = $_.'msDS-AllowedToDelegateTo'\n"
        "    }\n"
        "  } | ConvertTo-Json -Depth 3"
    ),
    # ------------------------------------------------------------------
    # schema — custom schema objects (non-Microsoft OIDs). Capped at 500.
    # Filters out standard MS, US-DoD, and Microsoft enterprise OIDs.
    # ------------------------------------------------------------------
    "schema": (
        "$schemaDN = (Get-ADRootDSE).schemaNamingContext\n"
        "$results = Get-ADObject -SearchBase $schemaDN -Filter *"
        " -Properties lDAPDisplayName,objectClass,adminDescription,governsID,attributeID |\n"
        "  Where-Object {\n"
        "    $oid = if ($_.governsID) { $_.governsID } else { $_.attributeID }\n"
        "    $oid -and\n"
        "    -not $oid.StartsWith('1.2.840.113556') -and\n"
        "    -not $oid.StartsWith('2.16.840.1.101.2') -and\n"
        "    -not $oid.StartsWith('1.3.6.1.4.1.311')\n"
        "  } |\n"
        "  Select-Object lDAPDisplayName,objectClass,adminDescription,governsID,attributeID |\n"
        "  Select-Object -First 500\n"
        "if ($results) { @($results) | ConvertTo-Json -Depth 3 } else { '[]' }"
    ),
    # ------------------------------------------------------------------
    # ntp_config — W32Time registry settings for the local DC.
    # Runs on each DC via collect_dc_inventory(). Uses local registry
    # reads (Get-ItemProperty) — fixes N-DC-1 (StdRegProv null on WS2012R2).
    # Adds NtpClientPollInterval and TimeSource (null with POLP by design).
    # ------------------------------------------------------------------
    "ntp_config": (
        "$dcFqdn = ($env:COMPUTERNAME + '.' + $env:USERDNSDOMAIN).ToLower()\n"
        "$timeSource = $null\n"
        "try {\n"
        "  $ts = (w32tm /query /source 2>&1) -join ''\n"
        "  if ($ts -notmatch '(?i)error|denied|0x8') { $timeSource = $ts.Trim() }\n"
        "} catch { $timeSource = $null }\n"
        "try {\n"
        "  [PSCustomObject]@{\n"
        "    DC                    = $dcFqdn\n"
        "    NtpServer             = (Get-ItemProperty"
        " 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\W32Time\\Parameters'"
        " -EA SilentlyContinue).NtpServer\n"
        "    Type                  = (Get-ItemProperty"
        " 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\W32Time\\Parameters'"
        " -EA SilentlyContinue).Type\n"
        "    AnnounceFlags         = (Get-ItemProperty"
        " 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\W32Time\\Config'"
        " -EA SilentlyContinue).AnnounceFlags\n"
        "    MaxNegPhaseCorrection = (Get-ItemProperty"
        " 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\W32Time\\Config'"
        " -EA SilentlyContinue).MaxNegPhaseCorrection\n"
        "    MaxPosPhaseCorrection = (Get-ItemProperty"
        " 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\W32Time\\Config'"
        " -EA SilentlyContinue).MaxPosPhaseCorrection\n"
        "    SpecialPollInterval   = (Get-ItemProperty"
        " 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\W32Time\\Config'"
        " -EA SilentlyContinue).SpecialPollInterval\n"
        "    NtpClientPollInterval = (Get-ItemProperty"
        " 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\W32Time\\TimeProviders\\NtpClient'"
        " -EA SilentlyContinue).SpecialPollInterval\n"
        "    VMICTimeProviderEnabled = (Get-ItemProperty"
        " 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\W32Time\\TimeProviders\\VMICTimeProvider'"
        " -EA SilentlyContinue).Enabled\n"
        "    TimeSource            = $timeSource\n"
        "    Status                = 'OK'\n"
        "  } | ConvertTo-Json -Depth 3\n"
        "} catch {\n"
        "  [PSCustomObject]@{ DC = $dcFqdn; Status = 'Unreachable' } | ConvertTo-Json -Depth 3\n"
        "}"
    ),
    # ------------------------------------------------------------------
    # eventlog_config — Event log settings for the local DC.
    # Runs on each DC via collect_dc_inventory(). Security log removed
    # (ACL not delegatable — N-POLP-3). DC-specific logs added.
    # Fields: DC, LogName, MaxSizeBytes, RetentionDays, OverflowAction, Status.
    # ------------------------------------------------------------------
    "eventlog_config": (
        "$dcFqdn = ($env:COMPUTERNAME + '.' + $env:USERDNSDOMAIN).ToLower()\n"
        "$dcLogs = @('Application', 'System', 'Directory Service',"
        " 'DNS Server', 'File Replication Service', 'DFS Replication')\n"
        "$results = foreach ($logName in $dcLogs) {\n"
        "  try {\n"
        "    $log = Get-WinEvent -ListLog $logName -ErrorAction Stop\n"
        "    [PSCustomObject]@{\n"
        "      DC             = $dcFqdn\n"
        "      LogName        = $logName\n"
        "      MaxSizeBytes   = $log.MaximumSizeInBytes\n"
        "      RetentionDays  = $log.LogRetentionDays\n"
        "      OverflowAction = $log.LogMode.ToString()\n"
        "      Status         = 'OK'\n"
        "    }\n"
        "  } catch { }\n"
        "}\n"
        "if ($results) { @($results) | ConvertTo-Json -Depth 3 } else { '[]' }"
    ),
    # ------------------------------------------------------------------
    # dc_windows_features — installed Windows Server roles on the
    # configured DC. Runs locally on the WinRM target (no -ComputerName,
    # no Get-ADDomainController). WMI loopback and Invoke-Command to self
    # both fail inside a WinRM session; local execution avoids both.
    # Returns a single-DC result for the configured DC.
    # FQDN built from $env:COMPUTERNAME + $env:USERDNSDOMAIN.
    # ------------------------------------------------------------------
    "dc_windows_features": (
        "$dcFqdn = ($env:COMPUTERNAME + '.' + $env:USERDNSDOMAIN).ToLower()\n"
        "try {\n"
        "  Import-Module ServerManager -ErrorAction SilentlyContinue\n"
        "  $features = Get-WindowsFeature |\n"
        "    Where-Object { $_.InstallState -eq 'Installed' -and $_.FeatureType -eq 'Role' } |\n"
        "    ForEach-Object { [PSCustomObject]@{ name = $_.Name; display_name = $_.DisplayName } }\n"
        "  @([PSCustomObject]@{ DC = $dcFqdn; Status = 'OK'; Features = @($features) })"
        " | ConvertTo-Json -Depth 5\n"
        "} catch {\n"
        "  @([PSCustomObject]@{ DC = $dcFqdn; Status = 'Unreachable'; Features = @() })"
        " | ConvertTo-Json -Depth 5\n"
        "}"
    ),
    # ------------------------------------------------------------------
    # dc_services — Running or Auto-start services on the configured DC.
    # Runs on each DC via collect_dc_inventory(). Get-CimInstance local,
    # no -ComputerName — script already executes on the DC via Invoke-Command.
    # -ErrorAction Stop propagates access-denied as a catchable exception.
    # Certified on WS2012R2 with POLP account (field test the test DC).
    # ------------------------------------------------------------------
    "dc_services": (
        "$dcFqdn = ($env:COMPUTERNAME + '.' + $env:USERDNSDOMAIN).ToLower()\n"
        "$cimError = $null\n"
        "try {\n"
        "  $services = Get-CimInstance -ClassName Win32_Service `\n"
        "    -ErrorAction Stop -ErrorVariable cimError |\n"
        "    Where-Object { $_.State -eq 'Running' -or $_.StartMode -eq 'Auto' } |\n"
        "    Select-Object @{N='name';         E={$_.Name}},\n"
        "                  @{N='display_name'; E={$_.DisplayName}},\n"
        "                  @{N='status';       E={$_.State}},\n"
        "                  @{N='start_type';   E={$_.StartMode}}\n"
        "  @([PSCustomObject]@{ DC = $dcFqdn; Status = 'OK'; Services = @($services) })"
        " | ConvertTo-Json -Depth 5\n"
        "} catch {\n"
        "  $errMsg = $_.Exception.Message\n"
        "  $statusValue = if ($errMsg -match '(?i)access.denied|0x80070005|0x80338104')"
        " { 'PermissionDenied' } else { 'Unreachable' }\n"
        "  @([PSCustomObject]@{ DC = $dcFqdn; Status = $statusValue; Services = @() })"
        " | ConvertTo-Json -Depth 5\n"
        "}"
    ),
    # ------------------------------------------------------------------
    # dc_installed_software — registry Uninstall key on the configured DC.
    # Runs locally on the WinRM target (no Invoke-Command, no -ComputerName).
    # Invoke-Command -ComputerName self is a WinRM double-hop even to the
    # same machine and fails without credential delegation. Removed.
    # Covers both 64-bit and WOW6432Node paths. De-duplicates by name.
    # ------------------------------------------------------------------
    "dc_installed_software": (
        "$dcFqdn = ($env:COMPUTERNAME + '.' + $env:USERDNSDOMAIN).ToLower()\n"
        "try {\n"
        "  $paths = @(\n"
        "    'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',\n"
        "    'HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*'\n"
        "  )\n"
        "  $soft = foreach ($path in $paths) {\n"
        "    Get-ItemProperty $path -ErrorAction SilentlyContinue |\n"
        "      Where-Object { $_.DisplayName } |\n"
        "      Select-Object @{N='name';         E={$_.DisplayName}},\n"
        "                    @{N='version';      E={$_.DisplayVersion}},\n"
        "                    @{N='vendor';       E={$_.Publisher}},\n"
        "                    @{N='install_date'; E={$_.InstallDate}},\n"
        "                    @{N='_source';      E={'registry'}},\n"
        "                    @{N='_note';        E={'data may include stale entries from incomplete uninstalls'}}\n"
        "  }\n"
        "  $dedup = if ($soft) { @($soft | Sort-Object name -Unique) } else { @() }\n"
        "  @([PSCustomObject]@{ DC = $dcFqdn; Status = 'OK'; Software = $dedup })"
        " | ConvertTo-Json -Depth 5\n"
        "} catch {\n"
        "  @([PSCustomObject]@{ DC = $dcFqdn; Status = 'Unreachable'; Software = @() })"
        " | ConvertTo-Json -Depth 5\n"
        "}"
    ),
    # ------------------------------------------------------------------
    # dc_file_locations — NTDS/log/SYSVOL paths from local registry.
    # Runs on each DC via collect_dc_inventory().
    # ------------------------------------------------------------------
    "dc_file_locations": (
        "$dcFqdn = ($env:COMPUTERNAME + '.' + $env:USERDNSDOMAIN).ToLower()\n"
        "try {\n"
        "  $ntdsParams = Get-ItemProperty"
        " 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\NTDS\\Parameters'"
        " -ErrorAction SilentlyContinue\n"
        "  $netlogon  = Get-ItemProperty"
        " 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Netlogon\\Parameters'"
        " -ErrorAction SilentlyContinue\n"
        "  [PSCustomObject]@{\n"
        "    DC           = $dcFqdn\n"
        "    DatabasePath = $ntdsParams.'DSA Working Directory'\n"
        "    LogPath      = $ntdsParams.'Database log files path'\n"
        "    SysvolPath   = $netlogon.SysVol\n"
        "    Status       = 'OK'\n"
        "  } | ConvertTo-Json -Depth 3\n"
        "} catch {\n"
        "  [PSCustomObject]@{ DC=$dcFqdn; DatabasePath=$null; LogPath=$null;"
        " SysvolPath=$null; Status='Unreachable' } | ConvertTo-Json -Depth 3\n"
        "}"
    ),
    # ------------------------------------------------------------------
    # dc_network_config — NIC configuration for the local DC.
    # Runs on each DC via collect_dc_inventory(). Get-CimInstance local,
    # no -ComputerName — script already executes on the DC via Invoke-Command.
    # Accessible with Remote Management Users (N-POLP-12).
    # Certified on WS2012R2 with POLP account (field test the test DC).
    # ------------------------------------------------------------------
    "dc_network_config": (
        "$dcFqdn = ($env:COMPUTERNAME + '.' + $env:USERDNSDOMAIN).ToLower()\n"
        "try {\n"
        "  $adapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration"
        " -ErrorAction Stop |\n"
        "    Where-Object { $_.IPEnabled } |\n"
        "    Select-Object Description,\n"
        "                  @{N='IPAddresses';    E={ $_.IPAddress -join ', ' }},\n"
        "                  @{N='DNSServers';     E={ $_.DNSServerSearchOrder -join ', ' }},\n"
        "                  @{N='DefaultGateway'; E={ $_.DefaultIPGateway -join ', ' }},\n"
        "                  DHCPEnabled\n"
        "  [PSCustomObject]@{ DC=$dcFqdn; Adapters=@($adapters); Status='OK' }"
        " | ConvertTo-Json -Depth 5\n"
        "} catch {\n"
        "  $errMsg = $_.Exception.Message\n"
        "  $statusValue = if ($errMsg -match '(?i)access.denied|0x80070005|0x80338104')"
        " { 'PermissionDenied' } else { 'Unreachable' }\n"
        "  [PSCustomObject]@{ DC=$dcFqdn; Adapters=@(); Status=$statusValue }"
        " | ConvertTo-Json -Depth 5\n"
        "}"
    ),
    # ------------------------------------------------------------------
    # schema_products — product presence detection via schema attribute
    # lookup. Scalar section (single dict). Covers LAPS (legacy + Windows),
    # Exchange, SCCM, Lync/SfB, AzureADConnect.
    # ------------------------------------------------------------------
    "schema_products": (
        "$schemaDN = (Get-ADRootDSE).schemaNamingContext\n"
        "function Test-SchemaObject($name) {\n"
        "  try { $null -ne (Get-ADObject -SearchBase $schemaDN"
        " -Filter \"lDAPDisplayName -eq '$name'\") } catch { $false }\n"
        "}\n"
        "[PSCustomObject]@{\n"
        "  LAPS_Legacy    = Test-SchemaObject 'ms-Mcs-AdmPwd'\n"
        "  LAPS_Windows   = Test-SchemaObject 'msLAPS-Password'\n"
        "  Exchange       = Test-SchemaObject 'msExchMailboxGuid'\n"
        "  SCCM           = Test-SchemaObject 'mSSMSSite'\n"
        "  Lync_SfB       = Test-SchemaObject 'msRTCSIP-UserEnabled'\n"
        "  AzureADConnect = Test-SchemaObject 'msDS-ExternalDirectoryObjectId'\n"
        "} | ConvertTo-Json -Depth 3"
    ),
    # ------------------------------------------------------------------
    # fsp — Foreign Security Principals with orphan detection.
    # IsOrphaned=True when the SID cannot be resolved to an NTAccount.
    # ------------------------------------------------------------------
    "fsp": (
        _PS_TARGET_RESOLUTION +
        "$domainDN = (Get-TargetDomain).DistinguishedName\n"
        "$fspDN = 'CN=ForeignSecurityPrincipals,' + $domainDN\n"
        "try {\n"
        "  $results = Get-ADObject -SearchBase $fspDN -Filter *"
        " -Properties objectSid,description |\n"
        "    Where-Object { $_.ObjectClass -eq 'foreignSecurityPrincipal' } |\n"
        "    ForEach-Object {\n"
        "      $sidStr = $_.objectSid.Value\n"
        "      $resolved = $null\n"
        "      try {\n"
        "        $sid = New-Object System.Security.Principal.SecurityIdentifier($sidStr)\n"
        "        $resolved = $sid.Translate([System.Security.Principal.NTAccount]).Value\n"
        "      } catch { $resolved = $null }\n"
        "      [PSCustomObject]@{\n"
        "        Name              = $_.Name\n"
        "        DistinguishedName = $_.DistinguishedName\n"
        "        SID               = $sidStr\n"
        "        ResolvedName      = $resolved\n"
        "        IsOrphaned        = ($null -eq $resolved)\n"
        "        Description       = $_.description\n"
        "      }\n"
        "    }\n"
        "  if ($results) { @($results) | ConvertTo-Json -Depth 3 } else { '[]' }\n"
        "} catch { '[]' }"
    ),
    # ------------------------------------------------------------------
    # _enumerate_dcs — internal script: returns a JSON array of DC FQDNs
    # from the forest. Prefixed with _ to signal it is not a queryable
    # section. Run on the entry-point DC by enumerate_dcs().
    # ------------------------------------------------------------------
    "_enumerate_dcs": (
        "Get-ADDomainController -Filter * | "
        "Select-Object -ExpandProperty HostName | "
        "ConvertTo-Json -Depth 1"
    ),
}


# Sections handled by collect_dc_inventory() — dispatched separately in query().
_DC_INVENTORY_SECTIONS: frozenset[str] = frozenset({
    "dc_windows_features",
    "dc_services",
    "dc_installed_software",
    "sysvol",
    "ntp_config",
    "eventlog_config",
    "dc_file_locations",
    "dc_network_config",
})

# Sections executed locally on the MCP server host via run_ps_local() — single-hop to DCs.
# These use -ComputerName in their scripts and must not run inside Invoke-Command.
_LOCAL_SECTIONS: frozenset[str] = frozenset({"dns", "dns_forwarders"})

# Empty data fields for each DC inventory section used in unreachable fallback.
_DC_INVENTORY_EMPTY_FIELDS: dict[str, dict] = {
    "dc_windows_features": {"Features": []},
    "dc_services": {"Services": []},
    "dc_installed_software": {"Software": []},
    "sysvol":           {"Mechanism": None, "State": None},
    "ntp_config":       {"NtpServer": None, "Type": None, "AnnounceFlags": None,
                         "MaxNegPhaseCorrection": None, "MaxPosPhaseCorrection": None,
                         "SpecialPollInterval": None, "NtpClientPollInterval": None,
                         "VMICTimeProviderEnabled": None, "TimeSource": None},
    "eventlog_config":  {},
    "dc_file_locations": {"DatabasePath": None, "LogPath": None, "SysvolPath": None},
    "dc_network_config": {"Adapters": []},
}



def _build_script(section: str) -> str:
    """Return the PowerShell script for *section*, or an error stub."""
    return _SCRIPTS.get(section, f"Write-Error 'Unknown section: {section}'")


# ---------------------------------------------------------------------------
# Connector
# ---------------------------------------------------------------------------

class LiveConnector:
    """Connects to AD via subprocess PowerShell and Invoke-Command."""

    def __init__(self, forest: "ForestConfig") -> None:
        self.forest = forest

    def _run_ps_on(self, dc_fqdn: str, script: str) -> Any:
        """Run a PowerShell script on a specific DC via Invoke-Command subprocess.

        Wraps the script in Invoke-Command targeting dc_fqdn with UseSSL and
        Kerberos authentication. The caller's process identity is used for
        Kerberos -- no explicit credentials required (Principle 3).
        Raises RuntimeError on non-zero exit code. Returns [] on empty output
        (Principle 10).
        """
        _validate_dc_fqdn(dc_fqdn)
        wrapped = (
            f"Invoke-Command -ComputerName {dc_fqdn} "
            f"-UseSSL -Authentication Kerberos "
            f"-ScriptBlock {{ {script} }}"
        )
        encoded = b64encode(wrapped.encode("utf_16_le")).decode("ascii")
        try:
            result = subprocess.run(
                ["powershell.exe", "-NonInteractive", "-EncodedCommand", encoded],
                capture_output=True,
                timeout=self.forest.timeout_seconds,
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(
                f"PowerShell timeout on DC '{dc_fqdn}' "
                f"(timeout={self.forest.timeout_seconds}s): {exc}"
            ) from exc
        if result.returncode != 0:
            stderr = result.stderr.decode(errors="replace").strip()
            raise RuntimeError(f"PowerShell error on {dc_fqdn}: {stderr}")
        raw = result.stdout.decode(errors="replace").strip()
        if not raw or raw == "null":
            return []
        return json.loads(raw)

    def run_ps(self, script: str) -> Any:
        """Run a PowerShell script on the forest entry-point DC via subprocess."""
        return self._run_ps_on(self.forest.dc, script)

    def run_ps_local(self, script: str) -> Any:
        """Run a PowerShell script directly on the MCP server host without Invoke-Command.

        Used for sections that need single-hop -ComputerName access to DCs
        (dns, dns_forwarders). Kerberos from the calling process is used
        implicitly (Principle 3). Raises RuntimeError on non-zero exit code.
        Returns [] on empty output (Principle 10).
        """
        encoded = b64encode(script.encode("utf_16_le")).decode("ascii")
        try:
            result = subprocess.run(
                ["powershell.exe", "-NonInteractive", "-EncodedCommand", encoded],
                capture_output=True,
                timeout=self.forest.timeout_seconds,
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(
                f"PowerShell local timeout "
                f"(timeout={self.forest.timeout_seconds}s): {exc}"
            ) from exc
        if result.returncode != 0:
            stderr = result.stderr.decode(errors="replace").strip()
            raise RuntimeError(f"PowerShell local error: {stderr}")
        raw = result.stdout.decode(errors="replace").strip()
        if not raw or raw == "null":
            return []
        return json.loads(raw)

    def enumerate_dcs(self) -> list[str]:
        """Return FQDNs of all DCs in the forest, queried from the entry-point DC.

        If the forest has a single DC, PS returns a bare string instead of an
        array — wraps it in a list. Falls back to [self.forest.dc] on any error
        (soft degradation — Principle 10).
        """
        try:
            result = self.run_ps(_SCRIPTS["_enumerate_dcs"])
            if isinstance(result, str):
                return [result]
            if isinstance(result, list):
                return result
            return [self.forest.dc]  # type: ignore[list-item]
        except Exception as e:
            eventlog.warn(f"DC enumeration failed, falling back to configured DC: {e}")
            return [self.forest.dc]  # type: ignore[list-item]

    def collect_dc_inventory(self, section: str) -> list[dict[str, Any]]:
        """Collect a DC inventory section from every DC in the forest.

        Enumerates all DCs via enumerate_dcs(), then calls _run_ps_on() for
        each DC sequentially. Unreachable DCs produce a fallback entry with
        Status='Unreachable' and empty data fields (Principle 10). If the
        forest has more than 10 DCs a warning entry is prepended to the result.
        """
        dcs = self.enumerate_dcs()
        results: list[dict[str, Any]] = []
        if len(dcs) > 10:
            results.append({
                "warning": (
                    f"Forest contains {len(dcs)} Domain Controllers. "
                    "Collection may take time."
                )
            })
        script = _SCRIPTS[section]
        for dc_fqdn in dcs:
            try:
                rows = self._run_ps_on(dc_fqdn, script)
                if isinstance(rows, list):
                    results.extend(rows)
                elif rows:
                    results.append(rows)
            except Exception as e:
                eventlog.warn_dc_unreachable(dc_fqdn, str(e))
                fallback: dict[str, Any] = {
                    "DC": dc_fqdn,
                    "Status": "Unreachable",
                }
                fallback.update(_DC_INVENTORY_EMPTY_FIELDS.get(section, {}))
                results.append(fallback)
        return results

    def query(self, section: str, **filters: Any) -> list[dict[str, Any]]:
        """Execute the appropriate PS script for a given AD section."""
        if section in _DC_INVENTORY_SECTIONS:
            rows = self.collect_dc_inventory(section)
        elif section in _LOCAL_SECTIONS:
            rows = self.run_ps_local(_build_script(section))
        else:
            script = _build_script(section)
            rows = self.run_ps(script)
        if not isinstance(rows, list):
            rows = [rows] if rows else []
        for key, value in filters.items():
            rows = [r for r in rows if str(r.get(key, "")).lower() == str(value).lower()]
        return rows

    def query_page(
        self,
        section: str,
        offset: int = 0,
        limit: int = 200,
        **filters: Any,
    ) -> dict[str, Any]:
        """Return a paginated page from a section, optionally filtered.

        Returns the same contract as OfflineConnector.query_page:
            {items, total, offset, limit, has_more}

        If the section has no PowerShell script implemented yet, returns an
        empty page without raising an error.
        """
        _empty: dict[str, Any] = {
            "items": [],
            "total": 0,
            "offset": offset,
            "limit": limit,
            "has_more": False,
        }

        if section not in _SCRIPTS:
            return _empty

        try:
            if section in _DC_INVENTORY_SECTIONS:
                rows = self.collect_dc_inventory(section)
            elif section in _LOCAL_SECTIONS:
                rows = self.run_ps_local(_SCRIPTS[section])
            else:
                rows = self.run_ps(_SCRIPTS[section])
        except (RuntimeError, ValueError):
            return _empty

        if not isinstance(rows, list):
            rows = [rows] if rows else []

        for key, value in filters.items():
            rows = [r for r in rows if str(r.get(key, "")).lower() == str(value).lower()]

        total = len(rows)
        page = rows[offset : offset + limit]
        return {
            "items": page,
            "total": total,
            "offset": offset,
            "limit": limit,
            "has_more": offset + len(page) < total,
        }

    def scalar(self, section: str) -> dict[str, Any] | None:
        results = self.query(section)
        return results[0] if results else None

    @property
    def is_live(self) -> bool:
        return True
