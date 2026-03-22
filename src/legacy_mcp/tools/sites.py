"""MCP tools — AD Sites and replication topology."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_sites(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 200,
    ) -> dict[str, Any]:
        """Return all AD sites with their associated subnets and DCs.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 200. Large enterprises can have 500+ sites.
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("sites", offset=offset, limit=limit)

    @mcp.tool()
    def get_site_links(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 200,
    ) -> dict[str, Any]:
        """Return all site links with cost, replication interval,
        schedule, and transport protocol (IP or SMTP).

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 200.
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("site_links", offset=offset, limit=limit)
