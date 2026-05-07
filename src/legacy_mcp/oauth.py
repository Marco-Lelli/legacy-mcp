"""Minimal OAuth 2.0 stub for LegacyMCP Profile B.

Implements the endpoints that mcp-remote requires to exchange a static API key
via client_credentials flow OR authorization_code + PKCE flow.
No actual OAuth infrastructure is involved: the issued token IS the API key.

Endpoints (no Bearer auth required -- handled before BearerApiKeyMiddleware):
  GET  /.well-known/oauth-authorization-server  -- discovery document
  GET  /authorize                               -- auto-approve PKCE (no UI)
  POST /register                                -- dynamic client registration
  POST /token                                   -- client_credentials OR authorization_code grant

All other requests are forwarded to the wrapped ASGI app (FastMCP).
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
import time
import uuid

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, RedirectResponse
from starlette.routing import Mount, Route
from starlette.types import ASGIApp

# In-memory store: auth_code → code_challenge (PKCE S256)
_pending_codes: dict[str, str] = {}

_TOKEN_TTL_SECONDS = 3600

# Nonce store for derived tokens: {nonce: expiry_timestamp}
_NONCE_STORE: dict[str, float] = {}


def _make_derived_token(api_key: str) -> str:
    """Generate a single-use derived token. Never exposes api_key."""
    nonce = secrets.token_hex(16)
    expiry = int(time.time()) + _TOKEN_TTL_SECONDS
    _NONCE_STORE[nonce] = float(expiry)
    payload = f"{expiry}|{nonce}"
    sig = hmac.new(api_key.encode(), payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}|{sig}"


def _verify_derived_token(token: str, api_key: str) -> bool:
    """Verify a derived token. Single-use: nonce is deleted after success."""
    now = time.time()
    expired = [n for n, exp in _NONCE_STORE.items() if exp < now]
    for n in expired:
        del _NONCE_STORE[n]

    try:
        expiry_str, nonce, sig = token.split("|", 2)
    except ValueError:
        return False

    stored_expiry = _NONCE_STORE.get(nonce)
    if stored_expiry is None or now > stored_expiry:
        return False

    payload = f"{expiry_str}|{nonce}"
    expected = hmac.new(
        api_key.encode(), payload.encode(), hashlib.sha256
    ).hexdigest()
    if not secrets.compare_digest(sig, expected):
        return False

    del _NONCE_STORE[nonce]
    return True


def build_oauth_app(api_key: str, fallback: ASGIApp, base_url: str) -> Starlette:

    async def oauth_discovery(request: Request) -> JSONResponse:
        return JSONResponse(
            {
                "issuer": base_url,
                "authorization_endpoint": f"{base_url}/authorize",
                "token_endpoint": f"{base_url}/token",
                "registration_endpoint": f"{base_url}/register",
                "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "client_credentials"],
                "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": ["client_secret_post"],
            }
        )

    async def authorize_endpoint(request: Request) -> RedirectResponse:
        """Auto-approve: generate a PKCE code and redirect immediately, no UI."""
        params = dict(request.query_params)
        redirect_uri = params.get("redirect_uri", "")
        state = params.get("state", "")
        code_challenge = params.get("code_challenge", "")

        code = secrets.token_urlsafe(32)
        _pending_codes[code] = code_challenge

        # C-1 fix: cap pending codes to prevent unbounded growth
        if len(_pending_codes) >= 100:
            oldest = list(_pending_codes.keys())[:10]
            for k in oldest:
                del _pending_codes[k]

        sep = "&" if "?" in redirect_uri else "?"
        location = f"{redirect_uri}{sep}code={code}&state={state}"
        return RedirectResponse(location, status_code=302)

    async def register_endpoint(request: Request) -> JSONResponse:
        try:
            body = await request.json()
            redirect_uris = body.get("redirect_uris", ["http://localhost"])
        except Exception:
            redirect_uris = ["http://localhost"]
        return JSONResponse(
            {
                "client_id": f"legacymcp-{uuid.uuid4()}",
                "client_secret": _make_derived_token(api_key),
                "redirect_uris": redirect_uris,
                "grant_types": ["authorization_code", "client_credentials"],
                "token_endpoint_auth_method": "client_secret_post",
            },
            status_code=201,
        )

    async def token_endpoint(request: Request) -> JSONResponse:
        form = await request.form()
        grant_type = str(form.get("grant_type", ""))

        if grant_type == "authorization_code":
            code = str(form.get("code", ""))
            code_verifier = str(form.get("code_verifier", ""))
            challenge = _pending_codes.pop(code, None)
            if challenge is None:
                return JSONResponse({"error": "invalid_grant"}, status_code=400)
            # Verifica PKCE S256: base64url(SHA256(verifier)) == challenge
            digest = (
                base64.urlsafe_b64encode(
                    hashlib.sha256(code_verifier.encode()).digest()
                )
                .rstrip(b"=")
                .decode()
            )
            if not secrets.compare_digest(digest, challenge):
                return JSONResponse({"error": "invalid_grant"}, status_code=400)
            return JSONResponse(
                {
                    "access_token": api_key,
                    "token_type": "Bearer",
                    "expires_in": 3600,
                }
            )

        elif grant_type == "client_credentials":
            client_secret = str(form.get("client_secret", ""))
            if not _verify_derived_token(client_secret, api_key):
                return JSONResponse({"error": "invalid_client"}, status_code=401)
            return JSONResponse(
                {
                    "access_token": api_key,
                    "token_type": "Bearer",
                    "expires_in": 3600,
                }
            )

        return JSONResponse({"error": "unsupported_grant_type"}, status_code=400)

    return Starlette(
        routes=[
            Route(
                "/.well-known/oauth-authorization-server",
                oauth_discovery,
                methods=["GET"],
            ),
            Route("/authorize", authorize_endpoint, methods=["GET"]),
            Route("/register", register_endpoint, methods=["POST"]),
            Route("/token", token_endpoint, methods=["POST"]),
            Mount("/", app=fallback),
        ]
    )
