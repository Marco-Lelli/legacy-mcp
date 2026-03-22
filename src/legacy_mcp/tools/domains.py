"""MCP tools — Domains and Default Password Policy."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_domains(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 200,
    ) -> dict[str, Any]:
        """Return all domains in the forest with their configuration:
        DNS name, functional level, and FSMO role holders.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 200. Bounded by AD architecture (typically 1-20 domains).
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("domains", offset=offset, limit=limit)

    @mcp.tool()
    def get_default_password_policy(
        domain: str | None = None,
        forest_name: str | None = None,
    ) -> dict[str, Any]:
        """Return the Default Domain Password Policy for a given domain,
        including minimum length, complexity, lockout thresholds, and history."""
        conn = workspace.connector(forest_name)
        results = conn.query("default_password_policy")
        if domain:
            results = [r for r in results if r.get("Domain", "").lower() == domain.lower()]
        return results[0] if results else {}
