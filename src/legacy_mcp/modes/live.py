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
    "forest": (
        "Get-ADForest | Select-Object Name,ForestMode,SchemaMaster,"
        "DomainNamingMaster,Sites,Domains | ConvertTo-Json -Depth 5"
    ),
    "domains": (
        "Get-ADDomain | Select-Object Name,DNSRoot,DomainMode,PDCEmulator,"
        "RIDMaster,InfrastructureMaster | ConvertTo-Json -Depth 5"
    ),
    "dcs": (
        "Get-ADDomainController -Filter * | Select-Object Name,HostName,"
        "IPv4Address,OperatingSystem,IsGlobalCatalog,IsReadOnly"
        " | ConvertTo-Json -Depth 5"
    ),
    "users": (
        "Get-ADUser -Filter * -Properties Enabled,PasswordNeverExpires,"
        "LastLogonDate | Select-Object SamAccountName,Enabled,"
        "PasswordNeverExpires,LastLogonDate | ConvertTo-Json -Depth 3"
    ),
    "groups": (
        "Get-ADGroup -Filter * -Properties Members | Select-Object "
        "Name,GroupCategory,GroupScope | ConvertTo-Json -Depth 3"
    ),
    "ous": (
        "Get-ADOrganizationalUnit -Filter * | Select-Object "
        "Name,DistinguishedName | ConvertTo-Json -Depth 3"
    ),
    "gpos": (
        "Get-GPO -All | Select-Object DisplayName,Id,GpoStatus"
        " | ConvertTo-Json -Depth 3"
    ),
    "sites": (
        "Get-ADReplicationSite -Filter * | Select-Object Name,Description"
        " | ConvertTo-Json -Depth 3"
    ),
    "trusts": (
        "Get-ADTrust -Filter * | Select-Object "
        "Name,Direction,TrustType,SelectiveAuthentication"
        " | ConvertTo-Json -Depth 3"
    ),
    "fgpp": (
        "Get-ADFineGrainedPasswordPolicy -Filter * | Select-Object "
        "Name,Precedence,MinPasswordLength,LockoutThreshold"
        " | ConvertTo-Json -Depth 3"
    ),
    "dns": (
        "Get-DnsServerZone | Select-Object ZoneName,ZoneType,IsDsIntegrated"
        " | ConvertTo-Json -Depth 3"
    ),
    "pki": (
        "Get-ADObject -SearchBase "
        "('CN=Public Key Services,CN=Services,CN=Configuration,' + "
        "(Get-ADDomain).DistinguishedName) "
        "-Filter * | Select-Object Name,DistinguishedName"
        " | ConvertTo-Json -Depth 3"
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
