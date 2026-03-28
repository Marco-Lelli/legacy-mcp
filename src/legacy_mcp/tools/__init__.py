"""MCP tool registration — wires all AD tools into the FastMCP instance."""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from mcp.server.fastmcp import FastMCP
    from legacy_mcp.workspace.workspace import Workspace

from legacy_mcp.tools import (
    workspace_info,
    forest,
    domains,
    dcs,
    sysvol,
    sites,
    users,
    groups,
    computers,
    ous,
    gpo,
    trusts,
    fgpp,
    dns,
    pki,
    snapshot,
)

_MODULES = [
    workspace_info,
    forest, domains, dcs, sysvol, sites,
    users, groups, computers, ous, gpo, trusts,
    fgpp, dns, pki,
    snapshot,
]


def register_all(mcp: "FastMCP", workspace: "Workspace", *, snapshot_path: str | None = None) -> None:
    for module in _MODULES:
        if module is snapshot:
            module.register(mcp, workspace, snapshot_path=snapshot_path)
        else:
            module.register(mcp, workspace)
