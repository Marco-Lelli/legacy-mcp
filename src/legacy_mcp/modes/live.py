"""Live Mode connector — executes PowerShell on Domain Controllers via WinRM."""

from __future__ import annotations

import json
from typing import Any, TYPE_CHECKING

if TYPE_CHECKING:
    from legacy_mcp.workspace.workspace import ForestConfig

from legacy_mcp.eventlog import writer as eventlog


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
}


def _looks_like_timeout(exc: Exception) -> bool:
    """Return True if the exception looks like a WinRM / network timeout."""
    name = type(exc).__name__.lower()
    msg = str(exc).lower()
    return "timeout" in name or "timed out" in msg or "timeout" in msg


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
            import winrm  # type: ignore[import]
            self._session = winrm.Session(
                target=self.forest.dc,
                auth=self._resolve_auth(),
                transport="kerberos" if self.forest.credentials == "gmsa" else "ntlm",
                # read_timeout_sec must be strictly greater than operation_timeout_sec.
                operation_timeout_sec=self.forest.timeout_seconds,
                read_timeout_sec=self.forest.timeout_seconds + 1,
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
        """Run a PowerShell script and return parsed JSON output."""
        session = self._ensure_connected()
        try:
            result = session.run_ps(script)
        except Exception as exc:
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

        if result.status_code != 0:
            raise RuntimeError(
                f"PowerShell error on {self.forest.dc}: {result.std_err.decode()}"
            )
        raw = result.std_out.decode().strip()
        if not raw or raw == "null":
            return []
        return json.loads(raw)

    def query(self, section: str, **filters: Any) -> list[dict[str, Any]]:
        """Execute the appropriate PS script for a given AD section."""
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
