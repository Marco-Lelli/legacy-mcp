"""LegacyMCP server entrypoint."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from mcp.server.fastmcp import FastMCP

from legacy_mcp.config import load_config
from legacy_mcp.workspace.workspace import Workspace
from legacy_mcp import tools


def create_server(config_path: str | Path) -> FastMCP:
    config = load_config(config_path)
    workspace = Workspace.from_config(config)

    mcp = FastMCP(
        "LegacyMCP",
        instructions=(
            "You are connected to an Active Directory assessment server. "
            "All operations are read-only. "
            "At the start of every session, call list_workspaces() first to "
            "discover which forests are available and confirm their data loaded "
            "correctly before running any other query. "
            "Use the forest 'name' values returned by list_workspaces as the "
            "'forest_name' argument for all other tools."
        ),
    )

    tools.register_all(mcp, workspace)
    return mcp


def main() -> None:
    parser = argparse.ArgumentParser(description="LegacyMCP — AD MCP Server")
    parser.add_argument(
        "--config",
        default="config/config.yaml",
        help="Path to configuration file (default: config/config.yaml)",
    )
    args = parser.parse_args()

    try:
        mcp = create_server(args.config)
    except (FileNotFoundError, ValueError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        sys.exit(1)

    mcp.run()


if __name__ == "__main__":
    main()
