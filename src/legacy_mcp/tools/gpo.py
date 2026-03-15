"""MCP tools — GPO Inventory."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_gpos(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return all GPOs with display name, GUID, status (enabled/disabled),
        and creation/modification dates."""
        conn = workspace.connector(forest_name)
        return conn.query("gpos")

    @mcp.tool()
    def get_gpo_links(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return GPO links to OUs, sites, and the domain root,
        including link enabled state and enforcement."""
        conn = workspace.connector(forest_name)
        return conn.query("gpo_links")

    @mcp.tool()
    def get_blocked_inheritance_ous(
        forest_name: str | None = None,
    ) -> list[dict[str, Any]]:
        """Return OUs with GPO inheritance blocked."""
        conn = workspace.connector(forest_name)
        return conn.query("blocked_inheritance")
