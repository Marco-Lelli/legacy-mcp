"""MCP tools — GPO Inventory."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_gpos(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 100,
    ) -> dict[str, Any]:
        """Return all GPOs with display name, GUID, status (enabled/disabled),
        and creation/modification dates.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 100. Enterprise environments can have 1000+ GPOs.
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("gpos", offset=offset, limit=limit)

    @mcp.tool()
    def get_gpo_links(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 100,
    ) -> dict[str, Any]:
        """Return GPO links to OUs, sites, and the domain root,
        including link enabled state and enforcement.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 100. Complex environments can have thousands of links
        (one row per GPO per target OU).
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("gpo_links", offset=offset, limit=limit)

    @mcp.tool()
    def get_blocked_inheritance_ous(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 100,
    ) -> dict[str, Any]:
        """Return OUs with GPO inheritance blocked.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 100.
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("blocked_inheritance", offset=offset, limit=limit)
