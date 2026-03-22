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
            "\n\n"
            "When producing an assessment report, always use this standard format:\n"
            "\n"
            "# Assessment Report - [forest name]\n"
            "Generated: [date] | Data collected: [JSON timestamp if available]\n"
            "\n"
            "## Executive Summary\n"
            "3-4 sentences maximum. Overall environment health, number of findings "
            "by severity, top priority action.\n"
            "\n"
            "## Security Findings\n"
            "\n"
            "### \U0001f534 High Severity\n"
            "For each finding:\n"
            "- Title\n"
            "- Affected object(s)\n"
            "- Risk description\n"
            "- Recommendation\n"
            "\n"
            "### \U0001f7e1 Medium Severity\n"
            "(same format)\n"
            "\n"
            "### \U0001f7e2 Low Severity\n"
            "(same format)\n"
            "\n"
            "## Inventory Summary\n"
            "- Forest and domains\n"
            "- Domain Controllers (with reachability status)\n"
            "- User counts by status\n"
            "- Computer counts by OS\n"
            "- Privileged group membership\n"
            "\n"
            "## Data Collection Gaps\n"
            "List any tools that returned empty results or errors, "
            "so the reader knows what could not be assessed.\n"
            "\n"
            "Always call list_workspaces() first. "
            "Always separate data collection from analysis into two distinct turns "
            "when the environment is large. "
            "Use 'Continue' if tool call limit is reached mid-report."
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
