"""MCP tools — SYSVOL state and replication."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_sysvol_state(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 100,
    ) -> dict[str, Any]:
        """Return SYSVOL replication state per DC: replication mechanism
        (FRS or DFSR), synchronization status, and any reported errors.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 100.
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("sysvol", offset=offset, limit=limit)
