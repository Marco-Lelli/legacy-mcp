"""MCP tools — AD Sites and replication topology."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_sites(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return all AD sites with their associated subnets and DCs."""
        conn = workspace.connector(forest_name)
        return conn.query("sites")

    @mcp.tool()
    def get_site_links(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return all site links with cost, replication interval,
        schedule, and transport protocol (IP or SMTP)."""
        conn = workspace.connector(forest_name)
        return conn.query("site_links")
