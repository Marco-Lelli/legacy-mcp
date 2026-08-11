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
        May include a "warnings" list in Live Mode (present only when
        something degraded this collection; absent otherwise).
        Default limit is 50 (records are heavy — Members field is embedded JSON).
        Use offset to page through large environments.
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("groups", offset=offset, limit=limit)

    @mcp.tool()
    def get_privileged_groups(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return membership of privileged groups with full nested resolution:
        Domain Admins, Enterprise Admins, Schema Admins, Administrators,
        Account Operators, Backup Operators, Print Operators, Server Operators.

        Returns a bare list (no pagination wrapper), so this tool does not
        surface a "warnings" field even in Live Mode -- any collection
        warning for this section is still captured in full in the server's
        EventLog. Use get_group_members or get_privileged_accounts if you
        need warnings in the response itself.
        """
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
        MemberObjectClass (user/computer/group/unresolved), MemberDistinguishedName,
        MemberEnabled (True/False for users and computers, null for nested groups).

        MemberObjectClass="unresolved" marks a member whose DN could not be
        resolved (orphaned SID, deleted object, foreign principal across a
        broken trust). Only MemberDistinguishedName is populated on those rows,
        with the raw DN -- useful for cleaning up broken references in AD.
        Filter on MemberObjectClass="unresolved" to list them.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 50. Large groups (e.g. Domain Computers) may require
        multiple pages.

        May include a "warnings" list in Live Mode -- always the aggregate
        count of groups that failed to enumerate in this domain, never the
        per-group detail (which can run into the hundreds on a large,
        partially-inaccessible domain); present only when at least one
        group failed, absent otherwise. The per-group detail is still
        captured in full in the server's EventLog.

        For privileged groups use get_privileged_groups -- it provides
        recursive nested expansion.
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("group_members", offset=offset, limit=limit, GroupName=group_name)
