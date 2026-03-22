"""MCP tools — Trust relationships."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_trusts(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 200,
    ) -> dict[str, Any]:
        """Return all trust relationships: type (External/Forest/Shortcut/Realm),
        direction (Bidirectional/Inbound/Outbound), transitivity,
        SID filtering, and SIDHistory state.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 200. Bounded by AD architecture (typically <20 trusts).
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("trusts", offset=offset, limit=limit)
