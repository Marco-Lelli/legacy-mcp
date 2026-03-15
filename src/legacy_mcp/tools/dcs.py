"""MCP tools — Domain Controllers, FSMO roles, EventLog config, NTP."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace


def register(mcp: "FastMCP", workspace: "Workspace") -> None:

    @mcp.tool()
    def get_domain_controllers(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return all Domain Controllers in the forest with OS version,
        IP address, GC/RODC status, site, and reachability state."""
        conn = workspace.connector(forest_name)
        return conn.query("dcs")

    @mcp.tool()
    def get_fsmo_roles(forest_name: str | None = None) -> dict[str, Any]:
        """Return the current FSMO role holders:
        Schema Master, Domain Naming Master, PDC Emulator, RID Master,
        Infrastructure Master — per domain."""
        conn = workspace.connector(forest_name)
        return conn.scalar("fsmo_roles") or {}

    @mcp.tool()
    def get_eventlog_config(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return EventLog configuration for each DC: log size, retention policy,
        and overwrite behavior for Application, System, and Security logs."""
        conn = workspace.connector(forest_name)
        return conn.query("eventlog_config")

    @mcp.tool()
    def get_ntp_config(forest_name: str | None = None) -> list[dict[str, Any]]:
        """Return NTP configuration from the registry of each DC:
        NtpServer, Type, and AnnounceFlags — retrieved per-DC via WinRM."""
        conn = workspace.connector(forest_name)
        return conn.query("ntp_config")
