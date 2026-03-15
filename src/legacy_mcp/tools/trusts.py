"""MCP tools — Trust relationships."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_trusts(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return all trust relationships: type (External/Forest/Shortcut/Realm),
        direction (Bidirectional/Inbound/Outbound), transitivity,
        SID filtering, and SIDHistory state."""
        conn = workspace.connector(forest_name)
        return conn.query("trusts")
