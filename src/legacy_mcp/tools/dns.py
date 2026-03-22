"""MCP tools — DNS configuration on Domain Controllers."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_dns_zones(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 200,
    ) -> dict[str, Any]:
        """Return DNS zones hosted on Domain Controllers: zone name, type
        (Primary/Secondary/Stub/Forwarder), AD-integrated flag, and replication scope.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 200. Environments with split-DNS or many application
        partitions can have 500+ zones.
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("dns", offset=offset, limit=limit)

    @mcp.tool()
    def get_dns_forwarders(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return DNS forwarder configuration per DC."""
        conn = workspace.connector(forest_name)
        return conn.query("dns_forwarders")
