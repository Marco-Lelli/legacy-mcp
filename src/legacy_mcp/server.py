"""LegacyMCP server entrypoint."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from mcp.server.fastmcp import FastMCP

from legacy_mcp.config import load_config
from legacy_mcp.config_registry import read_registry_config
from legacy_mcp.eventlog import writer as eventlog
from legacy_mcp.workspace.workspace import Workspace
from legacy_mcp import tools


def create_server(
    config_path: str | Path,
    *,
    host: str | None = None,
    port: int | None = None,
) -> FastMCP:
    """Create and return the configured FastMCP server instance.

    host and port, when provided, override any values in the config file's
    optional ``server:`` block, which in turn override FastMCP defaults
    (127.0.0.1:8000).  Pass them explicitly only for HTTP transports; stdio
    ignores them entirely.

    TLS (ssl_certfile / ssl_keyfile) is read exclusively from the config
    file's server: block and stored on ``mcp._tls_certfile`` /
    ``mcp._tls_keyfile`` so that ``main()`` can pass them directly to
    uvicorn when needed (FastMCP does not expose SSL params itself).
    """
    config = load_config(config_path)
    workspace = Workspace.from_config(config)

    # Resolve host/port/TLS: caller arg > config file > FastMCP built-in default.
    server_cfg: dict = config.get("server", {})
    resolved_host = host or server_cfg.get("host") or None
    resolved_port = port or (int(server_cfg["port"]) if server_cfg.get("port") else None)

    http_kwargs: dict = {}
    if resolved_host is not None:
        http_kwargs["host"] = resolved_host
    if resolved_port is not None:
        http_kwargs["port"] = resolved_port

    mcp = FastMCP(
        "LegacyMCP",
        **http_kwargs,
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

    tools.register_all(mcp, workspace, snapshot_path=server_cfg.get("snapshot_path") or None)

    # Attach resolved TLS paths so main() can pass them to uvicorn.
    # FastMCP does not expose ssl_certfile/ssl_keyfile in its settings.
    mcp._tls_certfile: str | None = server_cfg.get("ssl_certfile") or None
    mcp._tls_keyfile: str | None = server_cfg.get("ssl_keyfile") or None

    return mcp


def _run_with_tls(
    mcp: FastMCP,
    ssl_certfile: str,
    ssl_keyfile: str,
    api_key: str | None = None,
) -> None:
    """Start a Streamable HTTP server with TLS via uvicorn directly.

    FastMCP's run_streamable_http_async() does not forward ssl_certfile /
    ssl_keyfile to uvicorn.Config, so we build the uvicorn server ourselves
    using the same Starlette app that FastMCP would use.

    When api_key is provided the Starlette app is wrapped with
    BearerApiKeyMiddleware before being handed to uvicorn.  Profile A
    (stdio) never calls this function, so the middleware is never active
    for Profile A deployments.
    """
    import anyio
    import uvicorn

    async def _serve() -> None:
        app = mcp.streamable_http_app()
        if api_key:
            from legacy_mcp.oauth import build_oauth_app       # noqa: PLC0415
            from legacy_mcp.auth import BearerApiKeyMiddleware  # noqa: PLC0415
            app = build_oauth_app(api_key, fallback=app)
            app = BearerApiKeyMiddleware(app, api_key)
        config = uvicorn.Config(
            app,
            host=mcp.settings.host,
            port=mcp.settings.port,
            log_level=mcp.settings.log_level.lower(),
            ssl_certfile=ssl_certfile,
            ssl_keyfile=ssl_keyfile,
        )
        server = uvicorn.Server(config)
        await server.serve()

    anyio.run(_serve)


def main() -> None:
    parser = argparse.ArgumentParser(description="LegacyMCP - AD MCP Server")
    parser.add_argument(
        "--config",
        default=None,
        help="Path to configuration file (default: config/config.yaml)",
    )
    parser.add_argument(
        "--transport",
        default=None,
        choices=["stdio", "streamable-http", "sse"],
        help="Transport protocol (default: stdio)",
    )
    parser.add_argument(
        "--host",
        default=None,
        help="Bind host for HTTP transport, overrides config file (default: 127.0.0.1)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=None,
        help="Bind port for HTTP transport, overrides config file (default: 8000)",
    )
    args = parser.parse_args()

    # Priority: CLI > Windows registry > built-in default.
    registry = read_registry_config()

    config_path = args.config or registry.get("config_path") or "config/config.yaml"
    transport = args.transport or registry.get("transport") or "stdio"
    host = args.host or None          # registry host not supported; kept in config.yaml
    port = args.port or registry.get("port") or None
    api_key: str | None = registry.get("api_key") or None

    try:
        mcp = create_server(config_path, host=host, port=port)
    except (FileNotFoundError, ValueError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        sys.exit(1)

    ssl_certfile: str | None = getattr(mcp, "_tls_certfile", None)
    ssl_keyfile: str | None = getattr(mcp, "_tls_keyfile", None)

    if transport == "streamable-http" and ssl_certfile:
        eventlog.info(
            f"LegacyMCP starting: HTTPS {mcp.settings.host}:{mcp.settings.port} "
            f"auth={'enabled' if api_key else 'disabled'}"
        )
        _run_with_tls(mcp, ssl_certfile, ssl_keyfile, api_key=api_key)
    else:
        mcp.run(transport=transport)


if __name__ == "__main__":
    main()
