"""MCP tools — AD Computer accounts."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace

# Days without authentication before a computer is considered stale.
_STALE_DAYS = 90


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_computer_summary(forest_name: str | None = None) -> dict[str, Any]:
        """Return a summary of computer accounts in the domain:
        total count, enabled vs disabled, OS breakdown, stale machines
        (no logon in 90+ days), CNO (Cluster Name Objects), and VCO
        (Virtual Computer Objects).

        Use this for a quick OS inventory and hygiene overview before
        drilling into get_computers for the full list.
        """
        conn = workspace.connector(forest_name)
        computers = conn.query("computers")

        now = datetime.now(tz=timezone.utc)
        os_counts: dict[str, int] = {}
        stale = 0

        for c in computers:
            os_name = c.get("OperatingSystem") or "Unknown"
            os_counts[os_name] = os_counts.get(os_name, 0) + 1

            last_logon = c.get("LastLogonDate")
            if last_logon:
                try:
                    dt = datetime.fromisoformat(str(last_logon).rstrip("Z"))
                    if dt.tzinfo is None:
                        dt = dt.replace(tzinfo=timezone.utc)
                    if (now - dt).days > _STALE_DAYS:
                        stale += 1
                except ValueError:
                    pass
            else:
                stale += 1  # never logged on — treat as stale

        return {
            "total": len(computers),
            "enabled": sum(1 for c in computers if c.get("Enabled") == "True"),
            "disabled": sum(1 for c in computers if c.get("Enabled") == "False"),
            "stale_90d": stale,
            "cno": sum(1 for c in computers if c.get("IsCNO") == "True"),
            "vco": sum(1 for c in computers if c.get("IsVCO") == "True"),
            "trusted_for_delegation": sum(
                1 for c in computers if c.get("TrustedForDelegation") == "True"
            ),
            "os_breakdown": dict(sorted(os_counts.items())),
        }

    @mcp.tool()
    def get_computers(
        enabled: bool | None = None,
        stale_only: bool = False,
        delegation_only: bool = False,
        forest_name: str | None = None,
    ) -> list[dict[str, Any]]:
        """Return AD computer accounts with OS, last logon, password age,
        and Kerberos delegation flags (TrustedForDelegation,
        TrustedToAuthForDelegation, AllowedToDelegateTo).

        Parameters
        ----------
        enabled:
            True = only enabled accounts, False = only disabled, None = all.
        stale_only:
            If True, return only computers with no logon in 90+ days or
            that have never logged on. Useful for identifying stale machines.
        delegation_only:
            If True, return only computers with any form of Kerberos
            delegation configured (unconstrained or constrained).
            Use this to find delegation misconfigurations.
        forest_name:
            Target forest. Defaults to the first forest in the workspace.
        """
        conn = workspace.connector(forest_name)
        computers = conn.query("computers")

        if enabled is not None:
            computers = [c for c in computers if c.get("Enabled") == str(enabled)]

        if stale_only:
            now = datetime.now(tz=timezone.utc)
            filtered = []
            for c in computers:
                last_logon = c.get("LastLogonDate")
                is_stale = True
                if last_logon:
                    try:
                        dt = datetime.fromisoformat(str(last_logon).rstrip("Z"))
                        if dt.tzinfo is None:
                            dt = dt.replace(tzinfo=timezone.utc)
                        is_stale = (now - dt).days > _STALE_DAYS
                    except ValueError:
                        pass
                if is_stale:
                    filtered.append(c)
            computers = filtered

        if delegation_only:
            computers = [
                c for c in computers
                if c.get("TrustedForDelegation") == "True"
                or c.get("TrustedToAuthForDelegation") == "True"
                or c.get("AllowedToDelegateTo")
            ]

        return computers
