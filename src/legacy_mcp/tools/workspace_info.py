"""MCP tool — list_workspaces: session entry point."""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def _probe_forest(workspace: "Workspace", forest: Any, entry: dict[str, Any]) -> None:
    """Probe a single offline forest connector and update *entry* in-place."""
    file_path = Path(forest.file) if forest.file else None
    if file_path is None:
        entry["error"] = "No file path configured."
    elif not file_path.exists():
        entry["error"] = f"File not found: {forest.file}"
    else:
        try:
            conn = workspace.connector(forest.name)
            conn.scalar("forest")
            entry["loaded"] = True
        except Exception as exc:  # noqa: BLE001
            entry["error"] = str(exc)


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
            effective_mode = forest.mode if forest.mode is not None else workspace.mode
            entry: dict[str, Any] = {
                "name": forest.name,
                "mode": effective_mode.value,
                "relation": forest.relation.value,
                "loaded": False,
                "error": None,
            }
            if effective_mode.value == "offline":
                # Probe the connector — triggers lazy JSON load and
                # SQLite import; result is cached for subsequent calls.
                _probe_forest(workspace, forest, entry)
            else:
                # Live mode: reachability is verified on first real query.
                entry["loaded"] = True
                entry["dc"] = forest.dc or "auto-discover"
            results.append(entry)
        return results

    @mcp.tool()
    def reload_workspace() -> list[dict[str, Any]]:
        """Reload JSON data from disk for every forest without restarting Claude Desktop.

        Use this tool after the PowerShell collector has produced a new JSON file
        and you want the MCP server to pick up the updated data immediately.
        Each forest connector cache is cleared and the JSON is re-read from disk.

        Returns the same format as list_workspaces: name, mode, relation, loaded,
        and error for every forest. A failure on one forest does not prevent the
        others from reloading.
        """
        results = []
        for forest in workspace.forests:
            effective_mode = forest.mode if forest.mode is not None else workspace.mode
            entry: dict[str, Any] = {
                "name": forest.name,
                "mode": effective_mode.value,
                "relation": forest.relation.value,
                "loaded": False,
                "error": None,
            }
            if effective_mode.value == "offline":
                try:
                    # Clear the cached engine so the next probe re-reads from disk.
                    conn = workspace.connector(forest.name)
                    conn._engine = None
                except KeyError:
                    pass
                _probe_forest(workspace, forest, entry)
            else:
                # Live mode: no JSON cache to clear.
                entry["loaded"] = True
                entry["dc"] = forest.dc or "auto-discover"
            results.append(entry)
        return results
