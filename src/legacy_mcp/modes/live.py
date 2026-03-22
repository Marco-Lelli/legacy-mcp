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
        return json.loads(result.std_out.decode())

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
        except RuntimeError:
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
