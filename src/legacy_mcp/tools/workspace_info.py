"""MCP tool — list_workspaces: session entry point."""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def list_workspaces() -> list[dict[str, Any]]:
        """Return the list of all forests available in the current workspace.

        Call this tool automatically at the start of every session to discover
        what data is available before running any other query. The response
        tells you each forest name, its operating mode (live/offline), its role
        in the assessment (standalone, source, or destination for migration
        scenarios), and whether its data source loaded without errors.

        Use the 'name' field from this response as the 'forest_name' argument
        when calling any other tool that accepts it.
        """
        results = []
        for forest in workspace.forests:
            entry: dict[str, Any] = {
                "name": forest.name,
                "mode": workspace.mode.value,
                "relation": forest.relation.value,
                "loaded": False,
                "error": None,
            }

            if workspace.mode.value == "offline":
                file_path = Path(forest.file) if forest.file else None
                if file_path is None:
                    entry["error"] = "No file path configured."
                elif not file_path.exists():
                    entry["error"] = f"File not found: {forest.file}"
                else:
                    try:
                        # Probe the connector — triggers lazy JSON load and
                        # SQLite import; result is cached for subsequent calls.
                        conn = workspace.connector(forest.name)
                        conn.scalar("forest")
                        entry["loaded"] = True
                    except Exception as exc:  # noqa: BLE001
                        entry["error"] = str(exc)
            else:
                # Live mode: reachability is verified on first real query.
                entry["loaded"] = True
                entry["dc"] = forest.dc or "auto-discover"

            results.append(entry)

        return results
