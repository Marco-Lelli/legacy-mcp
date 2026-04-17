"""MCP tools — Domain Controllers, FSMO roles, EventLog config, NTP."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_domain_controllers(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 100,
    ) -> dict[str, Any]:
        """Return all Domain Controllers in the forest with OS version,
        IP address, GC/RODC status, site, reachability state, LDAP/SSL ports,
        FSMO roles held, and Server Core detection.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 100.
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("dcs", offset=offset, limit=limit)

    @mcp.tool()
    def get_fsmo_roles(forest_name: str | None = None) -> dict[str, Any]:
        """Return the current FSMO role holders:
        Schema Master, Domain Naming Master, PDC Emulator, RID Master,
        Infrastructure Master — per domain."""
        conn = workspace.connector(forest_name)
        return conn.scalar("fsmo_roles") or {}

    @mcp.tool()
    def get_eventlog_config(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 100,
    ) -> dict[str, Any]:
        """Return EventLog configuration for each DC: log size, retention policy,
        and overwrite behavior for Application, System, and Security logs.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 100 (5 DCs x 3 logs = 15 rows in a typical domain;
        up to 600 in a large forest).
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("eventlog_config", offset=offset, limit=limit)

    @mcp.tool()
    def get_ntp_config(
        forest_name: str | None = None,
        offset: int = 0,
        limit: int = 100,
    ) -> dict[str, Any]:
        """Return NTP configuration from the registry of each DC:
        NtpServer, Type, and AnnounceFlags -- retrieved per-DC via WinRM.

        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 100.
        """
        conn = workspace.connector(forest_name)
        return conn.query_page("ntp_config", offset=offset, limit=limit)

    @mcp.tool()
    def get_dc_features(
        forest_name: str | None = None,
        dc_name: str | None = None,
        offset: int = 0,
        limit: int = 50,
    ) -> dict[str, Any]:
        """Return installed Windows Server roles for each Domain Controller.
        Each item contains the DC hostname, status, and a nested list of
        installed roles (name, display_name).

        Use dc_name to filter results to a specific Domain Controller.
        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 50 (one entry per DC with nested role list).
        """
        conn = workspace.connector(forest_name)
        result = conn.query_page("dc_windows_features", offset=offset, limit=limit)
        if result["total"] == 0:
            result["_note"] = "data not available \u2014 collector < v1.6"
        if dc_name:
            result["items"] = [i for i in result["items"] if i.get("DC") == dc_name]
            result["total"] = len(result["items"])
        return result

    @mcp.tool()
    def get_dc_services(
        forest_name: str | None = None,
        dc_name: str | None = None,
        offset: int = 0,
        limit: int = 50,
    ) -> dict[str, Any]:
        """Return services that are Running or have Startup Type Auto
        for each Domain Controller. Covers: what is currently running,
        and what is configured to start automatically.

        Use dc_name to filter results to a specific Domain Controller.
        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 50.
        """
        conn = workspace.connector(forest_name)
        result = conn.query_page("dc_services", offset=offset, limit=limit)
        if result["total"] == 0:
            result["_note"] = "data not available \u2014 collector < v1.6"
        if dc_name:
            result["items"] = [i for i in result["items"] if i.get("DC") == dc_name]
            result["total"] = len(result["items"])
        return result

    @mcp.tool()
    def get_dc_software(
        forest_name: str | None = None,
        dc_name: str | None = None,
        offset: int = 0,
        limit: int = 50,
    ) -> dict[str, Any]:
        """Return installed software from the registry of each Domain Controller.
        Each item contains the DC hostname, status, and a nested list of
        installed software (name, version, vendor, install_date).

        Note: registry data may include stale entries from incomplete uninstalls.
        Use dc_name to filter results to a specific Domain Controller.
        Returns a paginated result: {items, total, offset, limit, has_more}.
        Default limit is 50.
        """
        conn = workspace.connector(forest_name)
        result = conn.query_page("dc_installed_software", offset=offset, limit=limit)
        if result["total"] == 0:
            result["_note"] = "data not available \u2014 collector < v1.6"
        if dc_name:
            result["items"] = [i for i in result["items"] if i.get("DC") == dc_name]
            result["total"] = len(result["items"])
        return result
