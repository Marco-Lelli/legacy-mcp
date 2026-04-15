"""Live Mode connector — executes PowerShell on Domain Controllers via WinRM."""

from __future__ import annotations

import json
import random
import time
import requests.adapters
import requests.exceptions
import urllib3
import urllib3.exceptions
from base64 import b64encode
from typing import Any, TYPE_CHECKING

if TYPE_CHECKING:
    from legacy_mcp.workspace.workspace import ForestConfig

from legacy_mcp.eventlog import writer as eventlog


class _SSLAdapter(requests.adapters.HTTPAdapter):
    """Custom SSL adapter to inject a specific SSL context into requests."""
    def __init__(self, ssl_context: "ssl.SSLContext", **kwargs: Any) -> None:
        self.ssl_context = ssl_context
        super().__init__(**kwargs)

    def init_poolmanager(self, *args: Any, **kwargs: Any) -> None:
        kwargs["ssl_context"] = self.ssl_context
        super().init_poolmanager(*args, **kwargs)


# ---------------------------------------------------------------------------
# winkerberos SPN separator fix
# ---------------------------------------------------------------------------
# pywinrm's vendored requests-kerberos builds the Kerberos SPN with '@' as
# separator (e.g. HTTP@dc01.contoso.local). Windows SSPI rejects this and
# returns "InitializeSecurityContext: The logon attempt failed". The correct
# format for SSPI is HTTP/dc01.contoso.local.
#
# We patch winkerberos.authGSSClientInit once at import time to normalise the
# separator. The vendor module imports winkerberos as 'kerberos' and accesses
# authGSSClientInit via attribute lookup on the module object at call time, so
# patching the module attribute is sufficient -- no venv files are modified.


def _patch_winkerberos_spn() -> None:
    try:
        import winkerberos as _wkrb  # type: ignore[import]
    except ImportError:
        return
    if getattr(_wkrb, "_spn_separator_patched", False):
        return
    _orig_init = _wkrb.authGSSClientInit

    def _fixed_init(spn: str, *args: Any, **kwargs: Any) -> Any:
        if "@" in spn and "/" not in spn:
            spn = spn.replace("@", "/", 1)
        if kwargs.get("principal") == "":
            kwargs["principal"] = None
        return _orig_init(spn, *args, **kwargs)

    _wkrb.authGSSClientInit = _fixed_init
    _wkrb._spn_separator_patched = True


_patch_winkerberos_spn()


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
        "$forest = Get-ADForest\n"
        "$schemaVersion = (Get-ADObject (Get-ADRootDSE).schemaNamingContext"
        " -Properties objectVersion).objectVersion\n"
        "[PSCustomObject]@{\n"
        "  Name              = $forest.Name\n"
        "  ForestMode        = $forest.ForestMode.ToString()\n"
        "  SchemaMaster      = $forest.SchemaMaster\n"
        "  DomainNamingMaster = $forest.DomainNamingMaster\n"
        "  Sites             = $forest.Sites -join ', '\n"
        "  Domains           = $forest.Domains -join ', '\n"
        "  GlobalCatalogs    = $forest.GlobalCatalogs -join ', '\n"
        "  SchemaVersion     = $schemaVersion\n"
        "} | ConvertTo-Json -Depth 5"
    ),
    # ------------------------------------------------------------------
    # domains — adds ChildDomains (joined) and Forest.
    # ------------------------------------------------------------------
    "domains": (
        "Get-ADDomain | ForEach-Object {\n"
        "  [PSCustomObject]@{\n"
        "    Name                 = $_.Name\n"
        "    DNSRoot              = $_.DNSRoot\n"
        "    DomainMode           = $_.DomainMode.ToString()\n"
        "    PDCEmulator          = $_.PDCEmulator\n"
        "    RIDMaster            = $_.RIDMaster\n"
        "    InfrastructureMaster = $_.InfrastructureMaster\n"
        "    ChildDomains         = $_.ChildDomains -join ', '\n"
        "    Forest               = $_.Forest\n"
        "  }\n"
        "} | ConvertTo-Json -Depth 5"
    ),
    # ------------------------------------------------------------------
    # dcs — adds Site, OperatingSystemVersion, Enabled, Reachable.
    # Test-Connection issues one ICMP ping per DC (same as collector).
    # ------------------------------------------------------------------
    "dcs": (
        "Get-ADDomainController -Filter * | ForEach-Object {\n"
        "  [PSCustomObject]@{\n"
        "    Name                   = $_.Name\n"
        "    HostName               = $_.HostName\n"
        "    IPv4Address            = $_.IPv4Address\n"
        "    Site                   = $_.Site\n"
        "    OperatingSystem        = $_.OperatingSystem\n"
        "    OperatingSystemVersion = $_.OperatingSystemVersion\n"
        "    IsGlobalCatalog        = $_.IsGlobalCatalog\n"
        "    IsReadOnly             = $_.IsReadOnly\n"
        "    Enabled                = $_.Enabled\n"
        "    Reachable              = (Test-Connection $_.HostName -Count 1 -Quiet)\n"
        "  }\n"
        "} | ConvertTo-Json -Depth 5"
    ),
    # ------------------------------------------------------------------
    # users — adds 11 fields; capped at 5000 (same limit as collector).
    # ------------------------------------------------------------------
    "users": (
        "Get-ADUser -Filter * -Properties Enabled,PasswordNeverExpires,LockedOut,"
        "LastLogonDate,PasswordLastSet,Description,mail,adminCount,"
        "TrustedForDelegation,TrustedToAuthForDelegation,'msDS-AllowedToDelegateTo' |\n"
        "  Select-Object -First 5000 |\n"
        "  ForEach-Object {\n"
        "    [PSCustomObject]@{\n"
        "      SamAccountName             = $_.SamAccountName\n"
        "      DisplayName                = $_.DisplayName\n"
        "      UserPrincipalName          = $_.UserPrincipalName\n"
        "      DistinguishedName          = $_.DistinguishedName\n"
        "      Mail                       = $_.mail\n"
        "      Enabled                    = $_.Enabled\n"
        "      PasswordNeverExpires       = $_.PasswordNeverExpires\n"
        "      LockedOut                  = $_.LockedOut\n"
        "      LastLogonDate              = $_.LastLogonDate\n"
        "      PasswordLastSet            = $_.PasswordLastSet\n"
        "      Description                = $_.Description\n"
        "      AdminCount                 = $_.adminCount\n"
        "      TrustedForDelegation       = $_.TrustedForDelegation\n"
        "      TrustedToAuthForDelegation = $_.TrustedToAuthForDelegation\n"
        "      AllowedToDelegateTo        = $_.'msDS-AllowedToDelegateTo'\n"
        "    }\n"
        "  } | ConvertTo-Json -Depth 3"
    ),
    # ------------------------------------------------------------------
    # groups — adds SamAccountName, DistinguishedName, AdminCount.
    # MemberCount uses Get-ADGroupMember | Measure-Object to handle
    # groups larger than the LDAP page boundary (returns -1 on error).
    # ------------------------------------------------------------------
    "groups": (
        "Get-ADGroup -Filter * -Properties adminCount | ForEach-Object {\n"
        "  $count = try {\n"
        "    (Get-ADGroupMember -Identity $_.DistinguishedName | Measure-Object).Count\n"
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
        "Get-ADReplicationSite -Filter * | ForEach-Object {\n"
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
        "Get-ADFineGrainedPasswordPolicy -Filter * | ForEach-Object {\n"
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
    # Uses first available DC as target for Get-DnsServerZone; requires
    # the DnsServer PS module (RSAT). Wrapped in try/catch.
    # ------------------------------------------------------------------
    "dns": (
        "$dc = (Get-ADDomainController -Filter * |"
        " Select-Object -First 1 -ExpandProperty HostName)\n"
        "try {\n"
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
        "  Get-ADObject -SearchBase $enrollmentDN -Filter * | ForEach-Object {\n"
        "    [PSCustomObject]@{\n"
        "      Name              = $_.Name\n"
        "      DistinguishedName = $_.DistinguishedName\n"
        "      ObjectClass       = $_.ObjectClass\n"
        "    }\n"
        "  } | ConvertTo-Json -Depth 3\n"
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
        "$forest = Get-ADForest\n"
        "$domain = Get-ADDomain\n"
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
        "$p = Get-ADDefaultDomainPasswordPolicy\n"
        "$domain = (Get-ADDomain).DNSRoot\n"
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
    # sysvol — DFSR replication state per DC. Degrades gracefully for
    # unreachable DCs (WMI query may fail on remote DCs).
    # ------------------------------------------------------------------
    "sysvol": (
        "Get-ADDomainController -Filter * | ForEach-Object {\n"
        "  $dcName = $_.HostName\n"
        "  try {\n"
        "    $dfsr = Get-WmiObject -Namespace 'root\\MicrosoftDFS'"
        " -Class DfsrReplicatedFolderInfo -ComputerName $dcName"
        " -Filter \"ReplicatedFolderName='SYSVOL Share'\" -ErrorAction Stop\n"
        "    [PSCustomObject]@{\n"
        "      DC        = $dcName\n"
        "      Mechanism = 'DFSR'\n"
        "      State     = if ($dfsr) { $dfsr.State } else { 'Not Found' }\n"
        "      Status    = 'OK'\n"
        "    }\n"
        "  } catch {\n"
        "    [PSCustomObject]@{ DC = $dcName; Mechanism = 'Unknown';"
        " State = 'Unreachable'; Status = 'Unreachable' }\n"
        "  }\n"
        "} | ConvertTo-Json -Depth 3"
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
        "$seen = @{}\n"
        "$groups = @('Domain Admins','Enterprise Admins','Schema Admins',"
        "'Administrators','Account Operators','Backup Operators',"
        "'Print Operators','Server Operators')\n"
        "$results = foreach ($g in $groups) {\n"
        "  try {\n"
        "    Get-ADGroupMember -Identity $g -Recursive |\n"
        "      Where-Object { $_.objectClass -eq 'user' } |\n"
        "      ForEach-Object {\n"
        "        if (-not $seen[$_.SamAccountName]) {\n"
        "          $seen[$_.SamAccountName] = $true\n"
        "          [PSCustomObject]@{ SamAccountName = $_.SamAccountName; Group = $g }\n"
        "        }\n"
        "      }\n"
        "  } catch { }\n"
        "}\n"
        "if ($results) { @($results) | ConvertTo-Json -Depth 3 } else { '[]' }"
    ),
    # ------------------------------------------------------------------
    # privileged_groups — per-group membership list (recursive) for the
    # 8 built-in privileged groups.
    # ------------------------------------------------------------------
    "privileged_groups": (
        "$names = @('Domain Admins','Enterprise Admins','Schema Admins',"
        "'Administrators','Account Operators','Backup Operators',"
        "'Print Operators','Server Operators')\n"
        "$results = foreach ($name in $names) {\n"
        "  try {\n"
        "    $members = Get-ADGroupMember -Identity $name -Recursive |\n"
        "      Select-Object SamAccountName, objectClass, distinguishedName\n"
        "    [PSCustomObject]@{ Group = $name; Members = @($members) }\n"
        "  } catch {\n"
        "    [PSCustomObject]@{ Group = $name; Members = @() }\n"
        "  }\n"
        "}\n"
        "@($results) | ConvertTo-Json -Depth 5"
    ),
    # ------------------------------------------------------------------
    # group_members — flat member list across ALL groups. Resolves
    # Enabled for user and computer members via individual AD lookups.
    # ------------------------------------------------------------------
    "group_members": (
        "$results = Get-ADGroup -Filter * | ForEach-Object {\n"
        "  $groupName = $_.Name\n"
        "  $groupDN   = $_.DistinguishedName\n"
        "  try {\n"
        "    Get-ADGroupMember -Identity $groupDN | ForEach-Object {\n"
        "      $m = $_\n"
        "      $enabled = $null\n"
        "      if ($m.objectClass -eq 'user') {\n"
        "        try { $enabled = (Get-ADUser -Identity $m.distinguishedName"
        " -Properties Enabled).Enabled } catch { }\n"
        "      } elseif ($m.objectClass -eq 'computer') {\n"
        "        try { $enabled = (Get-ADComputer -Identity $m.distinguishedName"
        " -Properties Enabled).Enabled } catch { }\n"
        "      }\n"
        "      [PSCustomObject]@{\n"
        "        GroupName               = $groupName\n"
        "        MemberSamAccountName    = $m.SamAccountName\n"
        "        MemberDisplayName       = $m.name\n"
        "        MemberObjectClass       = $m.objectClass\n"
        "        MemberDistinguishedName = $m.distinguishedName\n"
        "        MemberEnabled           = $enabled\n"
        "      }\n"
        "    }\n"
        "  } catch { }\n"
        "}\n"
        "if ($results) { @($results) | ConvertTo-Json -Depth 3 } else { '[]' }"
    ),
    # ------------------------------------------------------------------
    # gpo_links — GPO links on the domain root and all OUs. Requires
    # GPMC / GroupPolicy PS module (RSAT). Wrapped in try/catch.
    # ------------------------------------------------------------------
    "gpo_links": (
        "try {\n"
        "  $domainDN = (Get-ADDomain).DistinguishedName\n"
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
    # Requires DnsServer PS module (RSAT). Degrades per DC.
    # ------------------------------------------------------------------
    "dns_forwarders": (
        "try {\n"
        "  $dcs = (Get-ADDomainController -Filter *).HostName\n"
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
    # computers — full computer inventory; capped at 10 000 objects.
    # IsCNO/IsVCO derived from ServicePrincipalNames / isCriticalSystemObject.
    # ------------------------------------------------------------------
    "computers": (
        "Get-ADComputer -Filter * -Properties OperatingSystem,OperatingSystemVersion,"
        "Enabled,LastLogonDate,PasswordLastSet,Description,"
        "ServicePrincipalNames,isCriticalSystemObject,"
        "TrustedForDelegation,TrustedToAuthForDelegation,'msDS-AllowedToDelegateTo' |\n"
        "  Select-Object -First 10000 |\n"
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
    # ntp_config — W32Time registry settings per DC.
    # Uses WMI StdRegProv (-ComputerName) to avoid WinRM double-hop.
    # Fields: DC, NtpServer, Type, AnnounceFlags, MaxNeg/MaxPosPhaseCorrection,
    #         SpecialPollInterval, VMICTimeProviderEnabled, Status.
    # ------------------------------------------------------------------
    "ntp_config": (
        "$HKLM = [uint32]2147483650\n"
        "$paramKey  = 'SYSTEM\\CurrentControlSet\\Services\\W32Time\\Parameters'\n"
        "$configKey = 'SYSTEM\\CurrentControlSet\\Services\\W32Time\\Config'\n"
        "$vmicKey   = 'SYSTEM\\CurrentControlSet\\Services\\W32Time"
        "\\TimeProviders\\VMICTimeProvider'\n"
        "$dcs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName\n"
        "$results = foreach ($dcName in $dcs) {\n"
        "  try {\n"
        "    $reg = Get-WmiObject -Namespace root\\default -Class StdRegProv"
        " -ComputerName $dcName -ErrorAction Stop\n"
        "    $ntpServer   = ($reg.GetStringValue($HKLM, $paramKey,  'NtpServer')).sValue\n"
        "    $type        = ($reg.GetStringValue($HKLM, $paramKey,  'Type')).sValue\n"
        "    $announce    = ($reg.GetDWORDValue($HKLM,  $configKey, 'AnnounceFlags')).uValue\n"
        "    $maxNeg      = ($reg.GetDWORDValue($HKLM,  $configKey, 'MaxNegPhaseCorrection')).uValue\n"
        "    $maxPos      = ($reg.GetDWORDValue($HKLM,  $configKey, 'MaxPosPhaseCorrection')).uValue\n"
        "    $pollInt     = ($reg.GetDWORDValue($HKLM,  $configKey, 'SpecialPollInterval')).uValue\n"
        "    $vmicEnabled = ($reg.GetDWORDValue($HKLM,  $vmicKey,   'Enabled')).uValue\n"
        "    [PSCustomObject]@{\n"
        "      DC                      = $dcName\n"
        "      NtpServer               = $ntpServer\n"
        "      Type                    = $type\n"
        "      AnnounceFlags           = $announce\n"
        "      MaxNegPhaseCorrection   = $maxNeg\n"
        "      MaxPosPhaseCorrection   = $maxPos\n"
        "      SpecialPollInterval     = $pollInt\n"
        "      VMICTimeProviderEnabled = [bool]$vmicEnabled\n"
        "      Status                  = 'OK'\n"
        "    }\n"
        "  } catch {\n"
        "    [PSCustomObject]@{\n"
        "      DC                      = $dcName\n"
        "      NtpServer               = $null\n"
        "      Type                    = $null\n"
        "      AnnounceFlags           = $null\n"
        "      MaxNegPhaseCorrection   = $null\n"
        "      MaxPosPhaseCorrection   = $null\n"
        "      SpecialPollInterval     = $null\n"
        "      VMICTimeProviderEnabled = $null\n"
        "      Status                  = 'Unreachable'\n"
        "    }\n"
        "  }\n"
        "}\n"
        "if ($results) { @($results) | ConvertTo-Json -Depth 3 } else { '[]' }"
    ),
    # ------------------------------------------------------------------
    # eventlog_config — Application/System/Security log settings per DC.
    # Uses Get-WinEvent -ComputerName (Event Log Remoting Protocol / RPC)
    # to avoid WinRM double-hop.
    # Fields: DC, LogName, MaxSizeBytes, OverflowAction (LogMode), Status.
    # LogMode values: Circular / AutoBackup / Retain
    # ------------------------------------------------------------------
    "eventlog_config": (
        "$logNames = @('Application', 'System', 'Security')\n"
        "$dcs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName\n"
        "$results = foreach ($dcName in $dcs) {\n"
        "  foreach ($logName in $logNames) {\n"
        "    try {\n"
        "      $log = Get-WinEvent -ListLog $logName -ComputerName $dcName -ErrorAction Stop\n"
        "      [PSCustomObject]@{\n"
        "        DC             = $dcName\n"
        "        LogName        = $logName\n"
        "        MaxSizeBytes   = $log.MaximumSizeInBytes\n"
        "        OverflowAction = $log.LogMode.ToString()\n"
        "        Status         = 'OK'\n"
        "      }\n"
        "    } catch {\n"
        "      [PSCustomObject]@{\n"
        "        DC             = $dcName\n"
        "        LogName        = $logName\n"
        "        MaxSizeBytes   = $null\n"
        "        OverflowAction = $null\n"
        "        Status         = 'Unreachable'\n"
        "      }\n"
        "    }\n"
        "  }\n"
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
    # Runs locally on the WinRM target (no -ComputerName).
    # Uses Win32_Service (WMI local) for compatibility with PS 5.1 /
    # Windows Server 2012 R2 (Get-Service does not expose StartType on
    # PS 5.1). WMI StartMode 'Auto' is normalised to 'Automatic' to
    # match the collector output from Get-Service.StartType.ToString().
    # ------------------------------------------------------------------
    "dc_services": (
        "$dcFqdn = ($env:COMPUTERNAME + '.' + $env:USERDNSDOMAIN).ToLower()\n"
        "try {\n"
        "  $services = Get-WmiObject -Class Win32_Service |\n"
        "    Where-Object { $_.State -eq 'Running' -or $_.StartMode -eq 'Auto' } |\n"
        "    ForEach-Object {\n"
        "      [PSCustomObject]@{\n"
        "        name         = $_.Name\n"
        "        display_name = $_.DisplayName\n"
        "        status       = $_.State\n"
        "        start_type   = if ($_.StartMode -eq 'Auto') { 'Automatic' }"
        " else { $_.StartMode }\n"
        "      }\n"
        "    }\n"
        "  @([PSCustomObject]@{ DC = $dcFqdn; Status = 'OK'; Services = @($services) })"
        " | ConvertTo-Json -Depth 5\n"
        "} catch {\n"
        "  @([PSCustomObject]@{ DC = $dcFqdn; Status = 'Unreachable'; Services = @() })"
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
    "dc_windows_features", "dc_services", "dc_installed_software"
})

# Empty data fields for each DC inventory section used in unreachable fallback.
_DC_INVENTORY_EMPTY_FIELDS: dict[str, dict] = {
    "dc_windows_features": {"Features": []},
    "dc_services": {"Services": []},
    "dc_installed_software": {"Software": []},
}


def _looks_like_timeout(exc: Exception) -> bool:
    """Return True if the exception looks like a WinRM / network timeout."""
    name = type(exc).__name__.lower()
    msg = str(exc).lower()
    return "timeout" in name or "timed out" in msg or "timeout" in msg


_WINRM_MAX_RETRIES: int = 3
_WINRM_RETRY_BASE_DELAY: float = 1.0   # seconds
_WINRM_RETRY_MAX_DELAY: float = 12.0   # cap


def _winrm_backoff(attempt: int) -> float:
    """Exponential backoff with ±20% jitter."""
    delay = min(_WINRM_RETRY_BASE_DELAY * (2 ** attempt), _WINRM_RETRY_MAX_DELAY)
    jitter = random.uniform(-delay * 0.2, delay * 0.2)
    return max(0.0, delay + jitter)


def _is_transient_winrm_error(exc: Exception, _seen: set | None = None) -> bool:
    """Return True if exc is or wraps a transient WinRM connection error.

    Performs recursive unwrap of the exception chain (args[0], __cause__,
    __context__) to handle ConnectionResetError buried inside
    requests.exceptions.ConnectionError or urllib3.exceptions.ProtocolError.
    A 'seen' set prevents infinite loops on circular exception chains.
    """
    _TRANSIENT = (
        ConnectionResetError,
        ConnectionAbortedError,
        BrokenPipeError,
        EOFError,
    )
    _WRAPPERS = (
        requests.exceptions.ConnectionError,
        requests.exceptions.ChunkedEncodingError,
        urllib3.exceptions.ProtocolError,
        urllib3.exceptions.NewConnectionError,
    )
    if _seen is None:
        _seen = set()
    exc_id = id(exc)
    if exc_id in _seen:
        return False
    _seen.add(exc_id)

    if isinstance(exc, _TRANSIENT):
        return True
    if isinstance(exc, _WRAPPERS):
        # unwrap args[0]
        cause = exc.args[0] if exc.args else None
        if isinstance(cause, Exception) and _is_transient_winrm_error(cause, _seen):
            return True
        # unwrap __cause__ and __context__
        for chained in (exc.__cause__, exc.__context__):
            if isinstance(chained, Exception) and _is_transient_winrm_error(chained, _seen):
                return True
    return False


def _build_script(section: str) -> str:
    """Return the PowerShell script for *section*, or an error stub."""
    return _SCRIPTS.get(section, f"Write-Error 'Unknown section: {section}'")


# ---------------------------------------------------------------------------
# Connector
# ---------------------------------------------------------------------------

class LiveConnector:
    """Connects to AD via WinRM and runs PowerShell to collect data."""

    def __init__(self, forest: "ForestConfig") -> None:
        self.forest = forest
        self._session: Any = None

    def _ensure_connected(self) -> Any:
        if self._session is None:
            import ssl
            import winrm  # type: ignore[import]
            target = f"https://{self.forest.dc}:5986/wsman"
            self._session = winrm.Session(
                target=target,
                auth=self._resolve_auth(),
                transport="kerberos",
                kerberos_hostname_override=self.forest.dc,
                service="WSMAN",
                server_cert_validation="ignore",
                # read_timeout_sec must be strictly greater than operation_timeout_sec.
                operation_timeout_sec=self.forest.timeout_seconds,
                read_timeout_sec=self.forest.timeout_seconds + 1,
            )
            # Windows Server 2012 R2 uses cipher suites incompatible with
            # Python 3.11 default SECLEVEL=2. Inject a custom SSL context.
            ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ssl_context.check_hostname = False
            ssl_context.verify_mode = ssl.CERT_NONE
            ssl_context.set_ciphers("ALL:@SECLEVEL=0")
            self._session.protocol.transport.build_session()
            self._session.protocol.transport.session.mount(
                "https://",
                requests.adapters.HTTPAdapter(
                    pool_connections=1,
                    pool_maxsize=1,
                ),
            )
            self._session.protocol.transport.session.verify = False
            self._session.protocol.transport.session.mount(
                "https://",
                _SSLAdapter(ssl_context),
            )
        return self._session

    def _resolve_auth(self) -> tuple[str, str]:
        if self.forest.credentials == "gmsa":
            return ("", "")  # gMSA: Kerberos, no explicit credentials
        import os
        user = os.environ.get("LEGACYMCP_AD_USER", "")
        password = os.environ.get("LEGACYMCP_AD_PASSWORD", "")
        return (user, password)

    def run_ps(self, script: str) -> Any:
        """Run a PowerShell script and return parsed JSON output.

        Retries up to _WINRM_MAX_RETRIES times on transient WinRM errors
        (ConnectionResetError, ConnectionAbortedError, etc.) with exponential
        backoff. Opens and closes the WinRM shell explicitly on every attempt
        to avoid shell leaks that cause MaxShellsPerUser exhaustion on
        Windows Server 2012 R2.
        """
        # Encoding identical to winrm.Session.run_ps()
        encoded_ps = b64encode(script.encode("utf_16_le")).decode("ascii")
        command = "powershell -encodedcommand {0}".format(encoded_ps)

        last_exc: Exception | None = None
        for attempt in range(_WINRM_MAX_RETRIES + 1):
            session = self._ensure_connected()
            shell_id: Any = None
            try:
                shell_id = session.protocol.open_shell()
                command_id = session.protocol.run_command(shell_id, command, ())
                stdout, stderr, status_code = session.protocol.get_command_output(
                    shell_id, command_id
                )
                session.protocol.cleanup_command(shell_id, command_id)
                session.protocol.close_shell(shell_id)
                shell_id = None
            except Exception as exc:
                if shell_id is not None:
                    try:
                        session.protocol.close_shell(shell_id)
                    except Exception:
                        pass
                if _is_transient_winrm_error(exc):
                    self._session = None
                    last_exc = exc
                    if attempt < _WINRM_MAX_RETRIES:
                        time.sleep(_winrm_backoff(attempt))
                        continue
                    raise RuntimeError(
                        f"WinRM transient error on DC '{self.forest.dc}' "
                        f"after {_WINRM_MAX_RETRIES} retries: {exc}"
                    ) from exc
                if _looks_like_timeout(exc):
                    eventlog.warn_dc_unreachable(
                        self.forest.dc or "",
                        f"WinRM timeout after {self.forest.timeout_seconds}s: {exc}",
                    )
                    raise RuntimeError(
                        f"WinRM timeout on DC '{self.forest.dc}' "
                        f"(timeout={self.forest.timeout_seconds}s): {exc}"
                    ) from exc
                raise
            else:
                if status_code != 0:
                    raise RuntimeError(
                        f"PowerShell error on {self.forest.dc}: {stderr.decode()}"
                    )
                raw = stdout.decode().strip()
                if not raw or raw == "null":
                    return []
                return json.loads(raw)

        # Unreachable: the loop raises before exhausting retries on transient
        # errors, and non-transient errors raise immediately inside the loop.
        raise RuntimeError(  # pragma: no cover
            f"WinRM retries exhausted on DC '{self.forest.dc}': {last_exc}"
        )

    def run_ps_on(self, dc_fqdn: str, script: str) -> Any:
        """Run a PowerShell script on a specific DC (not the entry-point DC).

        Opens a dedicated WinRM session toward dc_fqdn, executes the script,
        then closes the session. Does not modify self._session or self.forest.dc.
        Applies the same retry/backoff logic as run_ps().
        """
        import ssl
        import winrm  # type: ignore[import]

        def _make_session() -> Any:
            target = f"https://{dc_fqdn}:5986/wsman"
            sess = winrm.Session(
                target=target,
                auth=self._resolve_auth(),
                transport="kerberos",
                kerberos_hostname_override=dc_fqdn,
                service="WSMAN",
                server_cert_validation="ignore",
                operation_timeout_sec=self.forest.timeout_seconds,
                read_timeout_sec=self.forest.timeout_seconds + 1,
            )
            ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ssl_ctx.check_hostname = False
            ssl_ctx.verify_mode = ssl.CERT_NONE
            ssl_ctx.set_ciphers("ALL:@SECLEVEL=0")
            sess.protocol.transport.build_session()
            sess.protocol.transport.session.mount(
                "https://",
                requests.adapters.HTTPAdapter(pool_connections=1, pool_maxsize=1),
            )
            sess.protocol.transport.session.verify = False
            sess.protocol.transport.session.mount("https://", _SSLAdapter(ssl_ctx))
            return sess

        encoded_ps = b64encode(script.encode("utf_16_le")).decode("ascii")
        command = "powershell -encodedcommand {0}".format(encoded_ps)

        session = _make_session()
        last_exc: Exception | None = None
        for attempt in range(_WINRM_MAX_RETRIES + 1):
            shell_id: Any = None
            try:
                shell_id = session.protocol.open_shell()
                command_id = session.protocol.run_command(shell_id, command, ())
                stdout, stderr, status_code = session.protocol.get_command_output(
                    shell_id, command_id
                )
                session.protocol.cleanup_command(shell_id, command_id)
                session.protocol.close_shell(shell_id)
                shell_id = None
            except Exception as exc:
                if shell_id is not None:
                    try:
                        session.protocol.close_shell(shell_id)
                    except Exception:
                        pass
                if _is_transient_winrm_error(exc):
                    session = _make_session()
                    last_exc = exc
                    if attempt < _WINRM_MAX_RETRIES:
                        time.sleep(_winrm_backoff(attempt))
                        continue
                    raise RuntimeError(
                        f"WinRM transient error on DC '{dc_fqdn}' "
                        f"after {_WINRM_MAX_RETRIES} retries: {exc}"
                    ) from exc
                if _looks_like_timeout(exc):
                    raise RuntimeError(
                        f"WinRM timeout on DC '{dc_fqdn}' "
                        f"(timeout={self.forest.timeout_seconds}s): {exc}"
                    ) from exc
                raise
            else:
                if status_code != 0:
                    raise RuntimeError(
                        f"PowerShell error on {dc_fqdn}: {stderr.decode()}"
                    )
                raw = stdout.decode().strip()
                if not raw or raw == "null":
                    return []
                return json.loads(raw)

        raise RuntimeError(  # pragma: no cover
            f"WinRM retries exhausted on DC '{dc_fqdn}': {last_exc}"
        )

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
        except Exception:
            return [self.forest.dc]  # type: ignore[list-item]

    def collect_dc_inventory(self, section: str) -> list[dict[str, Any]]:
        """Collect a DC inventory section from every DC in the forest.

        Enumerates all DCs via enumerate_dcs(), then calls run_ps_on() for
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
                rows = self.run_ps_on(dc_fqdn, script)
                if isinstance(rows, list):
                    results.extend(rows)
                elif rows:
                    results.append(rows)
            except Exception:
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
