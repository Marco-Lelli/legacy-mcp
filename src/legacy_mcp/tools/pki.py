"""MCP tools — PKI / CA Discovery from AD."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_certification_authorities(
        forest_name: str | None = None,
    ) -> list[dict[str, Any]]:
        """Return Certification Authorities registered in AD
        (CN=Enrollment Services, CN=Public Key Services).
        Includes CA common name and Distinguished Name.
        Note: detailed PKI configuration analysis is in the Enterprise layer."""
        conn = workspace.connector(forest_name)
        return conn.query("pki")
