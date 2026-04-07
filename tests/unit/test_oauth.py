"""Tests for src/legacy_mcp/oauth.py — minimal OAuth 2.0 stub."""

from __future__ import annotations

import base64
import hashlib
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
    """Unsupported grant_type (e.g. implicit) returns 400."""
    async with _async_client() as client:
        response = await client.post(
            "/token",
            content=f"grant_type=implicit&client_secret={_API_KEY}",
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


# ---------------------------------------------------------------------------
# POST /register — dynamic client registration
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_register_returns_201():
    """POST /register returns 201 with client_id and client_secret."""
    async with _async_client() as client:
        response = await client.post(
            "/register",
            json={"redirect_uris": ["http://localhost:12345/callback"]},
        )
    assert response.status_code == 201


@pytest.mark.anyio
async def test_register_returns_client_secret_equal_to_api_key():
    """client_secret in registration response equals the static API key."""
    async with _async_client() as client:
        response = await client.post(
            "/register",
            json={"redirect_uris": ["http://localhost:12345/callback"]},
        )
    data = response.json()
    assert data["client_secret"] == _API_KEY
    assert data["client_id"].startswith("legacymcp-")
    assert "authorization_code" in data["grant_types"]


@pytest.mark.anyio
async def test_register_preserves_redirect_uris():
    """redirect_uris sent in registration are echoed back."""
    uris = ["http://localhost:9999/cb"]
    async with _async_client() as client:
        response = await client.post("/register", json={"redirect_uris": uris})
    assert response.json()["redirect_uris"] == uris


# ---------------------------------------------------------------------------
# GET /authorize — PKCE auto-approve
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_authorize_redirects():
    """GET /authorize returns 302 redirect with code and state."""
    async with _async_client() as client:
        response = await client.get(
            "/authorize",
            params={
                "response_type": "code",
                "client_id": "legacymcp-test",
                "redirect_uri": "http://localhost:12345/callback",
                "state": "mystate",
                "code_challenge": "abc123",
                "code_challenge_method": "S256",
            },
            follow_redirects=False,
        )
    assert response.status_code == 302
    location = response.headers["location"]
    assert "code=" in location
    assert "state=mystate" in location


# ---------------------------------------------------------------------------
# POST /token — authorization_code + PKCE
# ---------------------------------------------------------------------------


def _pkce_pair() -> tuple[str, str]:
    """Return (verifier, challenge) for a valid PKCE S256 pair."""
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    digest = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()
    ).rstrip(b"=").decode()
    return verifier, digest


@pytest.mark.anyio
async def test_token_authorization_code_valid_pkce_returns_200():
    """authorization_code grant with valid PKCE verifier returns 200 + access_token."""
    verifier, challenge = _pkce_pair()

    async with _async_client() as client:
        # Step 1: get a code
        auth_resp = await client.get(
            "/authorize",
            params={
                "redirect_uri": "http://localhost:12345/cb",
                "state": "s",
                "code_challenge": challenge,
            },
            follow_redirects=False,
        )
        location = auth_resp.headers["location"]
        code = dict(p.split("=") for p in location.split("?", 1)[1].split("&") if "=" in p)["code"]

        # Step 2: exchange for token
        token_resp = await client.post(
            "/token",
            content=f"grant_type=authorization_code&code={code}&code_verifier={verifier}",
            headers={"content-type": "application/x-www-form-urlencoded"},
        )
    assert token_resp.status_code == 200
    data = token_resp.json()
    assert data["access_token"] == _API_KEY
    assert data["token_type"] == "Bearer"


@pytest.mark.anyio
async def test_token_authorization_code_wrong_verifier_returns_400():
    """authorization_code grant with wrong PKCE verifier returns 400 invalid_grant."""
    _, challenge = _pkce_pair()

    async with _async_client() as client:
        auth_resp = await client.get(
            "/authorize",
            params={
                "redirect_uri": "http://localhost:12345/cb",
                "state": "s",
                "code_challenge": challenge,
            },
            follow_redirects=False,
        )
        location = auth_resp.headers["location"]
        code = dict(p.split("=") for p in location.split("?", 1)[1].split("&") if "=" in p)["code"]

        token_resp = await client.post(
            "/token",
            content=f"grant_type=authorization_code&code={code}&code_verifier=wrong-verifier",
            headers={"content-type": "application/x-www-form-urlencoded"},
        )
    assert token_resp.status_code == 400
    assert token_resp.json()["error"] == "invalid_grant"


@pytest.mark.anyio
async def test_token_authorization_code_unknown_code_returns_400():
    """authorization_code grant with an unknown code returns 400 invalid_grant."""
    async with _async_client() as client:
        response = await client.post(
            "/token",
            content="grant_type=authorization_code&code=nonexistent&code_verifier=anything",
            headers={"content-type": "application/x-www-form-urlencoded"},
        )
    assert response.status_code == 400
    assert response.json()["error"] == "invalid_grant"


# ---------------------------------------------------------------------------
# Updated discovery checks for new fields
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_discovery_contains_authorization_endpoint():
    """Discovery document must include authorization_endpoint for PKCE flow."""
    async with _async_client() as client:
        response = await client.get("/.well-known/oauth-authorization-server")
    data = response.json()
    assert "authorization_endpoint" in data
    assert data["authorization_endpoint"].endswith("/authorize")


@pytest.mark.anyio
async def test_discovery_contains_registration_endpoint():
    """Discovery document must include registration_endpoint."""
    async with _async_client() as client:
        response = await client.get("/.well-known/oauth-authorization-server")
    data = response.json()
    assert "registration_endpoint" in data
    assert data["registration_endpoint"].endswith("/register")


@pytest.mark.anyio
async def test_discovery_contains_authorization_code_grant():
    """Discovery document must advertise authorization_code grant type."""
    async with _async_client() as client:
        response = await client.get("/.well-known/oauth-authorization-server")
    data = response.json()
    assert "authorization_code" in data["grant_types_supported"]
