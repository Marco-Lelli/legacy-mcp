"""MCP tools -- Foreign Security Principals."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_fsp(
        forest_name: str | None = None,
        orphaned_only: bool = False,
        offset: int = 0,
        limit: int = 200,
    ) -> dict[str, Any]:
        """Return Foreign Security Principals (FSPs) from the AD forest.

        FSPs are security principals from external trusted domains that have been
        granted access to resources in this domain. Orphaned FSPs (IsOrphaned=True)
        are principals whose SID can no longer be resolved -- typically indicating
        a removed trust or a deleted external account.

        Filters:
        orphaned_only:
            If True, return only FSPs that could not be resolved (IsOrphaned=True).
            Useful for identifying stale trust remnants or access control anomalies.
        forest_name:
            Target forest. Defaults to the first forest in the workspace.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        """
        conn = workspace.connector(forest_name)
        items = conn.query("fsp")

        if orphaned_only:
            items = [item for item in items if item.get("IsOrphaned") == "True"]

        total = len(items)
        page = items[offset: offset + limit]
        return {
            "items":    page,
            "total":    total,
            "offset":   offset,
            "limit":    limit,
            "has_more": offset + len(page) < total,
        }
