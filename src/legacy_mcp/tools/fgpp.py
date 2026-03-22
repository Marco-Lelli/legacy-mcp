"""MCP tools — Fine-Grained Password Policies."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_fgpp(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 200,
    ) -> dict[str, Any]:
        """Return all Fine-Grained Password Policies (PSO) with precedence,
        password settings (min length, complexity, history, age),
        lockout settings, and the groups/users they apply to.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 200. Bounded by design (rare to exceed 10 PSOs).
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("fgpp", offset=offset, limit=limit)
