"""Live Mode connector — executes PowerShell on Domain Controllers via WinRM."""

from __future__ import annotations

import json
from typing import Any, TYPE_CHECKING

if TYPE_CHECKING:
    from legacy_mcp.workspace.workspace import ForestConfig


class LiveConnector:
    """Connects to AD via WinRM and runs PowerShell to collect data."""

    def __init__(self, forest: "ForestConfig") -> None:
        self.forest = forest
        self._session: Any = None

    def _ensure_connected(self) -> Any:
        if self._session is None:
            import winrm
            self._session = winrm.Session(
                target=self.forest.dc,
                auth=self._resolve_auth(),
                transport="kerberos" if self.forest.credentials == "gmsa" else "ntlm",
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
        result = session.run_ps(script)
        if result.status_code != 0:
            raise RuntimeError(
                f"PowerShell error on {self.forest.dc}: {result.std_err.decode()}"
            )
        return json.loads(result.std_out.decode())

    def query(self, section: str, **filters: Any) -> list[dict[str, Any]]:
        """Execute the appropriate PS script for a given AD section."""
        script = _build_script(section, **filters)
        return self.run_ps(script)

    def scalar(self, section: str) -> dict[str, Any] | None:
        results = self.query(section)
        return results[0] if results else None

    @property
    def is_live(self) -> bool:
        return True


def _build_script(section: str, **filters: Any) -> str:
    """Return a minimal PowerShell snippet that outputs JSON for a given section."""
    scripts: dict[str, str] = {
        "forest": "Get-ADForest | Select-Object Name,ForestMode,SchemaMaster,DomainNamingMaster,Sites,Domains | ConvertTo-Json -Depth 5",
        "domains": "Get-ADDomain | Select-Object Name,DNSRoot,DomainMode,PDCEmulator,RIDMaster,InfrastructureMaster | ConvertTo-Json -Depth 5",
        "dcs": "Get-ADDomainController -Filter * | Select-Object Name,HostName,IPv4Address,OperatingSystem,IsGlobalCatalog,IsReadOnly | ConvertTo-Json -Depth 5",
        "users": "Get-ADUser -Filter * -Properties Enabled,PasswordNeverExpires,LastLogonDate | Select-Object SamAccountName,Enabled,PasswordNeverExpires,LastLogonDate | ConvertTo-Json -Depth 3",
        "groups": "Get-ADGroup -Filter * -Properties Members | Select-Object Name,GroupCategory,GroupScope | ConvertTo-Json -Depth 3",
        "ous": "Get-ADOrganizationalUnit -Filter * | Select-Object Name,DistinguishedName | ConvertTo-Json -Depth 3",
        "gpos": "Get-GPO -All | Select-Object DisplayName,Id,GpoStatus | ConvertTo-Json -Depth 3",
        "sites": "Get-ADReplicationSite -Filter * | Select-Object Name,Description | ConvertTo-Json -Depth 3",
        "trusts": "Get-ADTrust -Filter * | Select-Object Name,Direction,TrustType,SelectiveAuthentication | ConvertTo-Json -Depth 3",
        "fgpp": "Get-ADFineGrainedPasswordPolicy -Filter * | Select-Object Name,Precedence,MinPasswordLength,LockoutThreshold | ConvertTo-Json -Depth 3",
        "dns": "Get-DnsServerZone | Select-Object ZoneName,ZoneType,IsDsIntegrated | ConvertTo-Json -Depth 3",
        "pki": "Get-ADObject -SearchBase 'CN=Public Key Services,CN=Services,CN=Configuration,DC=domain,DC=com' -Filter * | Select-Object Name,DistinguishedName | ConvertTo-Json -Depth 3",
    }
    return scripts.get(section, f"Write-Error 'Unknown section: {section}'")
