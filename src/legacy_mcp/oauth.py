"""Minimal OAuth 2.0 stub for LegacyMCP Profile B.

Implements the two endpoints that mcp-remote --static-oauth-client-info
requires to exchange a static API key via client_credentials flow.
No actual OAuth infrastructure is involved: the issued token IS the API key.

Endpoints (no Bearer auth required -- handled before BearerApiKeyMiddleware):
  GET  /.well-known/oauth-authorization-server  -- discovery document
  POST /token                                    -- client_credentials grant

All other requests are forwarded to the wrapped ASGI app (FastMCP).
"""

from __future__ import annotations

import secrets

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route
from starlette.types import ASGIApp


def build_oauth_app(api_key: str, fallback: ASGIApp) -> Starlette:
    """Return a Starlette app that handles OAuth endpoints and delegates the rest.

    The discovery document and token endpoint are mounted at the top level.
    Every other path falls through to ``fallback`` (the FastMCP Starlette app).

    Args:
        api_key: static API key.  A POST /token with a matching client_secret
                 receives a Bearer token equal to this key.
        fallback: the underlying ASGI application (FastMCP) for all other paths.
    """

    async def oauth_discovery(request: Request) -> JSONResponse:
        # Build URLs from the Host header so they match exactly what the client
        # is connecting to, regardless of the server binding address (0.0.0.0).
        host = request.headers.get("host", "localhost")
        base_url = f"https://{host}"
        return JSONResponse(
            {
                "issuer": base_url,
                "token_endpoint": f"{base_url}/token",
                "grant_types_supported": ["client_credentials"],
                "token_endpoint_auth_methods_supported": ["client_secret_post"],
            }
        )

    async def token_endpoint(request: Request) -> JSONResponse:
        form = await request.form()
        grant_type = str(form.get("grant_type", ""))
        if grant_type != "client_credentials":
            return JSONResponse({"error": "unsupported_grant_type"}, status_code=400)
        client_secret = str(form.get("client_secret", ""))
        if not secrets.compare_digest(client_secret, api_key):
            return JSONResponse({"error": "invalid_client"}, status_code=401)
        return JSONResponse(
            {
                "access_token": api_key,
                "token_type": "Bearer",
                "expires_in": 3600,
            }
        )

    return Starlette(
        routes=[
            Route(
                "/.well-known/oauth-authorization-server",
                oauth_discovery,
                methods=["GET"],
            ),
            Route("/token", token_endpoint, methods=["POST"]),
            Mount("/", app=fallback),
        ]
    )
