"""MCP tools — DNS configuration on Domain Controllers."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_dns_zones(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return DNS zones hosted on Domain Controllers: zone name, type
        (Primary/Secondary/Stub/Forwarder), AD-integrated flag, and replication scope."""
        conn = workspace.connector(forest_name)
        return conn.query("dns")

    @mcp.tool()
    def get_dns_forwarders(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return DNS forwarder configuration per DC."""
        conn = workspace.connector(forest_name)
        return conn.query("dns_forwarders")
