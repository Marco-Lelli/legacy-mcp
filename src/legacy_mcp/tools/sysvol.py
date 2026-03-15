"""MCP tools — SYSVOL state and replication."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_sysvol_state(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return SYSVOL replication state per DC: replication mechanism
        (FRS or DFSR), synchronization status, and any reported errors."""
        conn = workspace.connector(forest_name)
        return conn.query("sysvol")
