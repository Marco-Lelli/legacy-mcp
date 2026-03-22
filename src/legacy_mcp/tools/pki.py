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
        offset: int = 0,
        limit: int = 200,
    ) -> dict[str, Any]:
        """Return Certification Authorities registered in AD
        (CN=Enrollment Services, CN=Public Key Services).
        Includes CA common name and Distinguished Name.
        Note: detailed PKI configuration analysis is in the Enterprise layer.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 200. Bounded by design (typically 1-5 CAs per forest).
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("pki", offset=offset, limit=limit)
