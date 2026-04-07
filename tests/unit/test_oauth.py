"""Tests for src/legacy_mcp/oauth.py — minimal OAuth 2.0 stub."""

from __future__ import annotations

import json

import httpx
import pytest
from starlette.applications import Starlette
from starlette.responses import PlainTextResponse
from starlette.routing import Route

from legacy_mcp.oauth import build_oauth_app

_API_KEY = "test-static-key-abc"


def _make_app(api_key: str = _API_KEY) -> Starlette:
    """Build an oauth app whose fallback is a simple 200 OK echo."""

    async def fallback_home(request):
        return PlainTextResponse("ok from fallback")

    fallback = Starlette(routes=[Route("/mcp", fallback_home, methods=["GET"])])
    return build_oauth_app(api_key, fallback=fallback)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _client(api_key: str = _API_KEY) -> httpx.Client:
    return httpx.Client(
        transport=httpx.WSGITransport(app=None),  # unused -- we use ASGITransport
    )


def _async_client(api_key: str = _API_KEY) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        transport=httpx.ASGITransport(app=_make_app(api_key)),
        base_url="https://testserver",
    )


# ---------------------------------------------------------------------------
# GET /.well-known/oauth-authorization-server
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_discovery_returns_200():
    """Feature H: discovery endpoint returns 200 with required fields."""
    async with _async_client() as client:
        response = await client.get("/.well-known/oauth-authorization-server")
    assert response.status_code == 200


@pytest.mark.anyio
async def test_discovery_contains_token_endpoint():
    """Feature H: discovery document contains token_endpoint."""
    async with _async_client() as client:
        response = await client.get("/.well-known/oauth-authorization-server")
    data = response.json()
    assert "token_endpoint" in data
    assert data["token_endpoint"].endswith("/token")


@pytest.mark.anyio
async def test_discovery_contains_grant_types_supported():
    """Feature H: discovery document contains client_credentials grant type."""
    async with _async_client() as client:
        response = await client.get("/.well-known/oauth-authorization-server")
    data = response.json()
    assert "grant_types_supported" in data
    assert "client_credentials" in data["grant_types_supported"]


@pytest.mark.anyio
async def test_discovery_issuer_reflects_host_header():
    """Feature H: issuer is built from the Host header, not the binding address."""
    async with _async_client() as client:
        response = await client.get(
            "/.well-known/oauth-authorization-server",
            headers={"host": "LORENZO.house.local:8000"},
        )
    data = response.json()
    assert data["issuer"] == "https://LORENZO.house.local:8000"
    assert data["token_endpoint"] == "https://LORENZO.house.local:8000/token"


# ---------------------------------------------------------------------------
# POST /token
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_token_correct_secret_returns_200():
    """Feature H: POST /token with matching client_secret returns 200."""
    async with _async_client() as client:
        response = await client.post(
            "/token",
            content=f"grant_type=client_credentials&client_secret={_API_KEY}",
            headers={"content-type": "application/x-www-form-urlencoded"},
        )
    assert response.status_code == 200


@pytest.mark.anyio
async def test_token_correct_secret_returns_access_token():
    """Feature H: access_token in response equals the API key."""
    async with _async_client() as client:
        response = await client.post(
            "/token",
            content=f"grant_type=client_credentials&client_secret={_API_KEY}",
            headers={"content-type": "application/x-www-form-urlencoded"},
        )
    data = response.json()
    assert data["access_token"] == _API_KEY
    assert data["token_type"] == "Bearer"
    assert "expires_in" in data


@pytest.mark.anyio
async def test_token_wrong_secret_returns_401():
    """Feature H: POST /token with wrong client_secret returns 401."""
    async with _async_client() as client:
        response = await client.post(
            "/token",
            content="grant_type=client_credentials&client_secret=wrong-secret",
            headers={"content-type": "application/x-www-form-urlencoded"},
        )
    assert response.status_code == 401
    assert response.json()["error"] == "invalid_client"


@pytest.mark.anyio
async def test_token_missing_grant_type_returns_400():
    """Feature H: POST /token without grant_type returns 400."""
    async with _async_client() as client:
        response = await client.post(
            "/token",
            content=f"client_secret={_API_KEY}",
            headers={"content-type": "application/x-www-form-urlencoded"},
        )
    assert response.status_code == 400


@pytest.mark.anyio
async def test_token_wrong_grant_type_returns_400():
    """Feature H: unsupported grant_type returns 400."""
    async with _async_client() as client:
        response = await client.post(
            "/token",
            content=f"grant_type=authorization_code&client_secret={_API_KEY}",
            headers={"content-type": "application/x-www-form-urlencoded"},
        )
    assert response.status_code == 400
    assert response.json()["error"] == "unsupported_grant_type"


# ---------------------------------------------------------------------------
# Fallback and unimplemented paths
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_mcp_path_forwarded_to_fallback():
    """/mcp is forwarded to the inner FastMCP app, not intercepted by OAuth."""
    async with _async_client() as client:
        response = await client.get("/mcp")
    # Our test fallback returns 200 "ok from fallback"
    assert response.status_code == 200


@pytest.mark.anyio
async def test_unimplemented_well_known_returns_404():
    """/.well-known/oauth-protected-resource has no handler: Starlette returns 404.

    Bug G regression: this path must NOT return 401 (which would trigger OAuth
    flow in mcp-remote).  The OAuth app delegates to Starlette routing which
    returns 404 for unregistered paths.
    """
    async with _async_client() as client:
        response = await client.get("/.well-known/oauth-protected-resource")
    assert response.status_code == 404
