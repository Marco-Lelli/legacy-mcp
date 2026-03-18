"""MCP tools — AD Groups."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_groups(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return all AD groups with category (Security/Distribution),
        scope (Global/DomainLocal/Universal), and member count."""
        conn = workspace.connector(forest_name)
        return conn.query("groups")

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
    ) -> list[dict[str, Any]]:
        """Return the direct members of a specific group.

        Each row contains: GroupName, MemberSamAccountName, MemberDisplayName,
        MemberObjectClass (user / computer / group), MemberDistinguishedName,
        MemberEnabled (True/False for users and computers, null for nested groups).

        For privileged groups (Domain Admins, Enterprise Admins, Schema Admins,
        Administrators, Account Operators, Backup Operators, Print Operators,
        Server Operators), use get_privileged_groups instead — it provides
        recursive nested expansion.
        """
        conn = workspace.connector(forest_name)
        return conn.query("group_members", GroupName=group_name)
