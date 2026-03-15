"""MCP tools — Forest and AD Schema."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_forest_info(forest_name: str | None = None) -> dict[str, Any]:
        """Return forest-level information: name, functional level, schema version,
        FSMO roles (SchemaMaster, DomainNamingMaster), sites, and optional features
        such as the AD Recycle Bin."""
        conn = workspace.connector(forest_name)
        result = conn.scalar("forest")
        return result or {}

    @mcp.tool()
    def get_optional_features(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return the list of optional AD features and their enabled state
        (e.g. Recycle Bin, Privileged Access Management)."""
        conn = workspace.connector(forest_name)
        return conn.query("optional_features")

    @mcp.tool()
    def get_schema_extensions(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return custom schema classes and attributes added to the AD schema
        beyond the default Microsoft base schema."""
        conn = workspace.connector(forest_name)
        return conn.query("schema")
