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
    ous,
    gpo,
    trusts,
    fgpp,
    dns,
    pki,
)

_MODULES = [
    workspace_info,
    forest, domains, dcs, sysvol, sites,
    users, groups, ous, gpo, trusts,
    fgpp, dns, pki,
]


def register_all(mcp: "FastMCP", workspace: "Workspace") -> None:
    for module in _MODULES:
        module.register(mcp, workspace)
