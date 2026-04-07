"""Bearer token authentication middleware for LegacyMCP Profile B.

This module provides:
  - validate_request(headers, api_key): pure function that checks the
    Authorization header against the expected Bearer token.
  - BearerApiKeyMiddleware: ASGI middleware that wraps the Starlette app
    returned by FastMCP and enforces the token on every HTTP request.

Profile A (stdio) never instantiates BearerApiKeyMiddleware -- the
middleware is only injected in _run_with_tls() when an api_key is present.
This ensures zero impact on Profile A deployments.

Future: replace the api_key string with an Entra ID OIDC validator for
Profile B-enterprise without touching this module's interface.
"""

from __future__ import annotations

import secrets
from typing import Callable

from legacy_mcp.eventlog import writer as _eventlog


def validate_request(headers: dict, api_key: str) -> bool:
    """Return True if the Authorization header carries the expected Bearer token.

    Uses secrets.compare_digest to prevent timing-based side-channel attacks.

    Args:
        headers: mapping of lowercase header names to their string values.
        api_key: the expected raw API key string.

    Returns:
        True  -- header is present and equals "Bearer <api_key>"
        False -- header is absent, malformed, or carries the wrong token
    """
    auth = headers.get("authorization", "")
    if not auth.lower().startswith("bearer "):
        return False
    token = auth[len("bearer "):]
    return secrets.compare_digest(token, api_key)


class BearerApiKeyMiddleware:
    """ASGI middleware that enforces Bearer token authentication.

    Wraps any ASGI application. Every incoming HTTP request must carry:
        Authorization: Bearer <api-key>

    Requests that are missing the header or carry an invalid token receive
    HTTP 401 Unauthorized with a JSON body and a WWW-Authenticate header.
    Non-HTTP scope types (lifespan, websocket) are forwarded unchanged.

    NOTE on DPAPI machine-scope: the api_key passed to this class is
    decrypted at server startup from HKLM\\SOFTWARE\\LegacyMCP\\ApiKey
    using DPAPI with CRYPTPROTECT_LOCAL_MACHINE scope.  Machine-scope DPAPI
    is accessible to any process running on the same machine regardless of
    the user context (including the NSSM service account).  This is
    intentional and acceptable for Profile B-core, whose threat model
    assumes network-level access control (TLS + perimeter firewall).
    For Profile B-enterprise or multi-tenant scenarios, re-evaluate this
    choice: consider user-scope DPAPI tied to the service account or a
    dedicated secrets manager such as Azure Key Vault.
    """

    _BODY_401 = b'{"error":"Unauthorized"}'

    def __init__(self, app: Callable, api_key: str) -> None:
        self._app = app
        self._api_key = api_key

    async def __call__(self, scope: dict, receive: Callable, send: Callable) -> None:
        if scope["type"] != "http":
            await self._app(scope, receive, send)
            return

        # OAuth paths bypass Bearer auth and are forwarded to the app directly.
        # /.well-known/* -- discovery endpoints; oauth.py returns 200 for the
        #   ones it implements, Starlette returns 404 for the rest.
        # /token          -- has its own client_secret validation in oauth.py.
        path = scope.get("path", "")
        if path.startswith("/.well-known/") or path == "/token":
            await self._app(scope, receive, send)
            return

        headers: dict[str, str] = {
            k.decode("latin-1").lower(): v.decode("latin-1")
            for k, v in scope.get("headers", [])
        }

        if not validate_request(headers, self._api_key):
            client = scope.get("client")
            client_ip = client[0] if client else "unknown"
            _eventlog.warn(
                f"Auth failed: {scope.get('method', '?')} {scope.get('path', '?')} "
                f"from {client_ip}"
            )
            await self._send_401(send)
            return

        await self._app(scope, receive, send)

    async def _send_401(self, send: Callable) -> None:
        await send(
            {
                "type": "http.response.start",
                "status": 401,
                "headers": [
                    [b"content-type", b"application/json"],
                    [b"content-length", str(len(self._BODY_401)).encode()],
                    # WWW-Authenticate intentionally omitted: mcp-remote interprets
                    # it as an OAuth discovery trigger.  LegacyMCP uses a static
                    # Bearer token -- no OAuth flow is involved.
                ],
            }
        )
        await send({"type": "http.response.body", "body": self._BODY_401})

