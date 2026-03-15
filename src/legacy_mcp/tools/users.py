"""MCP tools — AD Users."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_user_summary(forest_name: str | None = None) -> dict[str, Any]:
        """Return user counts by state: total, enabled, disabled, locked out,
        password-never-expires, and accounts inactive for more than 90 days."""
        conn = workspace.connector(forest_name)
        users = conn.query("users")
        return {
            "total": len(users),
            "enabled": sum(1 for u in users if u.get("Enabled") == "True"),
            "disabled": sum(1 for u in users if u.get("Enabled") == "False"),
            "password_never_expires": sum(1 for u in users if u.get("PasswordNeverExpires") == "True"),
            "locked_out": sum(1 for u in users if u.get("LockedOut") == "True"),
        }

    @mcp.tool()
    def get_privileged_accounts(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return accounts that are members of privileged groups
        (Domain Admins, Enterprise Admins, Schema Admins, Administrators)."""
        conn = workspace.connector(forest_name)
        return conn.query("privileged_accounts")

    @mcp.tool()
    def get_users(
        enabled: bool | None = None,
        forest_name: str | None = None,
    ) -> list[dict[str, Any]]:
        """Return AD user accounts. Optionally filter by enabled state."""
        conn = workspace.connector(forest_name)
        filters = {}
        if enabled is not None:
            filters["Enabled"] = str(enabled)
        return conn.query("users", **filters)
