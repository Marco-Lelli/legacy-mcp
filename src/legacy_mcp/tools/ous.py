"""MCP tools — Organizational Units."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_ous(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 100,
    ) -> dict[str, Any]:
        """Return the complete OU tree with distinguished names,
        parent OU, and whether inheritance is blocked.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 100. Large environments may have 1000+ OUs.
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("ous", offset=offset, limit=limit)
