"""MCP tools — Organizational Units."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_ous(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return the complete OU tree with distinguished names,
        parent OU, and whether inheritance is blocked."""
        conn = workspace.connector(forest_name)
        return conn.query("ous")
