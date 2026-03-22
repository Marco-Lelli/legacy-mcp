"""MCP tools — AD Groups."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_groups(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 50,
    ) -> dict[str, Any]:
        """Return AD groups with category (Security/Distribution),
        scope (Global/DomainLocal/Universal), and member count.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 50 (records are heavy — Members field is embedded JSON).
        Use offset to page through large environments.
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("groups", offset=offset, limit=limit)

    @mcp.tool()
    def get_privileged_groups(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return membership of privileged groups with full nested resolution:
        Domain Admins, Enterprise Admins, Schema Admins, Administrators,
        Account Operators, Backup Operators, Print Operators, Server Operators."""
        conn = workspace.connector(forest_name)
        return conn.query("privileged_groups")

    @mcp.tool()
    def get_group_members(
        group_name: str,
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 50,
    ) -> dict[str, Any]:
        """Return the direct members of a specific group.

        Each row: GroupName, MemberSamAccountName, MemberDisplayName,
        MemberObjectClass (user/computer/group), MemberDistinguishedName,
        MemberEnabled (True/False for users and computers, null for nested groups).

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 50. Large groups (e.g. Domain Computers) may require
        multiple pages.

        For privileged groups use get_privileged_groups -- it provides
        recursive nested expansion.
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("group_members", offset=offset, limit=limit, GroupName=group_name)
