"""Live Mode connector — executes PowerShell on Domain Controllers via subprocess."""

from __future__ import annotations

import json
import subprocess
from base64 import b64encode
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
        "$domain = Get-ADDomain\n"
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
        "Get-ADDomainController -Filter * | ForEach-Object {\n"
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
    # users — adds 11 fields; capped at 5000 (same limit as collector).
    # ------------------------------------------------------------------
    "users": (
        "Get-ADUser -Filter * -Properties Enabled,PasswordNeverExpires,LockedOut,"
        "LastLogonDate,PasswordLastSet,Description,mail,adminCount,SIDHistory,"
        "TrustedForDelegation,TrustedToAuthForDelegation,'msDS-AllowedToDelegateTo',"
        "userAccountControl,homeDirectory,homeDrive,primaryGroupID |\n"
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
        "      SIDHistory                 = @($_.SIDHistory | ForEach-Object { $_.Value })\n"
        "      TrustedForDelegation       = $_.TrustedForDelegation\n"
        "      TrustedToAuthForDelegation = $_.TrustedToAuthForDelegation\n"
        "      AllowedToDelegateTo        = ($_.'msDS-AllowedToDelegateTo') -join ', '\n"
        "      PasswordNotRequired        = [bool]($_.userAccountControl -band 0x20)\n"
        "      HomeDrive                  = $_.homeDrive\n"
        "      HomeDirectory              = $_.homeDirectory\n"
        "      PrimaryGroupID             = $_.primaryGroupID\n"
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
    # Runs locally on LORENZO via run_ps_local() — single hop to PDC.
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
    # sysvol — DFSR/FRS replication state for the local DC. Runs on each
    # DC via collect_dc_inventory(). Dual-mode: WMI DFSR, then LDAP
    # CN=DFSR-GlobalSettings, then NtFrs registry fallback (Principle 9).
    # ------------------------------------------------------------------
    "sysvol": (
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
        "    $domainDN = (Get-ADDomain).DistinguishedName\n"
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
    # Runs locally on LORENZO via run_ps_local() — iterates all DCs,
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
    # Certified on WS2012R2 with POLP account (field test PUPP).
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
    # Certified on WS2012R2 with POLP account (field test PUPP).
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
        "$domainDN = (Get-ADDomain).DistinguishedName\n"
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

# Sections executed locally on LORENZO via run_ps_local() — single-hop to DCs.
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
        """Run a PowerShell script directly on LORENZO without Invoke-Command.

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
        except Exception:
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
