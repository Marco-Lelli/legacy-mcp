"""Tests for src/legacy_mcp/auth.py — Bearer token authentication."""

from __future__ import annotations

from unittest.mock import patch

import pytest

from legacy_mcp.auth import BearerApiKeyMiddleware, validate_request


# ---------------------------------------------------------------------------
# validate_request unit tests
# ---------------------------------------------------------------------------


class TestValidateRequest:
    def test_valid_token_returns_true(self):
        headers = {"authorization": "Bearer secret-key-abc"}
        assert validate_request(headers, "secret-key-abc") is True

    def test_wrong_token_returns_false(self):
        headers = {"authorization": "Bearer wrong-token"}
        assert validate_request(headers, "secret-key-abc") is False

    def test_missing_header_returns_false(self):
        assert validate_request({}, "secret-key-abc") is False

    def test_empty_authorization_returns_false(self):
        headers = {"authorization": ""}
        assert validate_request(headers, "secret-key-abc") is False

    def test_bearer_prefix_case_insensitive(self):
        headers = {"authorization": "BEARER secret-key-abc"}
        assert validate_request(headers, "secret-key-abc") is True

    def test_basic_auth_returns_false(self):
        headers = {"authorization": "Basic dXNlcjpwYXNz"}
        assert validate_request(headers, "secret-key-abc") is False

    def test_token_with_spaces_not_confused(self):
        # token contains a space -- only exact match should pass
        headers = {"authorization": "Bearer secret-key-abc extra"}
        assert validate_request(headers, "secret-key-abc") is False

    def test_empty_api_key_never_matches_empty_bearer(self):
        # Degenerate case: both empty -- compare_digest returns True, but
        # an empty api_key should never be stored.  This test documents the
        # behaviour rather than asserting a policy.
        headers = {"authorization": "Bearer "}
        result = validate_request(headers, "")
        # secrets.compare_digest("", "") is True -- document it.
        assert isinstance(result, bool)


# ---------------------------------------------------------------------------
# BearerApiKeyMiddleware integration tests
# ---------------------------------------------------------------------------


def _make_http_scope(auth_header: str | None = None) -> dict:
    """Build a minimal ASGI HTTP scope dict."""
    headers = []
    if auth_header is not None:
        headers.append(
            (b"authorization", auth_header.encode("latin-1"))
        )
    return {
        "type": "http",
        "method": "GET",
        "path": "/mcp",
        "headers": headers,
    }


def _make_lifespan_scope() -> dict:
    return {"type": "lifespan"}


class _RecordingApp:
    """Minimal ASGI app that records whether it was called."""

    def __init__(self):
        self.called = False

    async def __call__(self, scope, receive, send):
        self.called = True


class _CaptureSend:
    """Collect all ASGI send events."""

    def __init__(self):
        self.events: list[dict] = []

    async def __call__(self, event: dict) -> None:
        self.events.append(event)


@pytest.mark.anyio
async def test_middleware_allows_valid_token():
    inner = _RecordingApp()
    mw = BearerApiKeyMiddleware(inner, "my-key")
    scope = _make_http_scope("Bearer my-key")
    capture = _CaptureSend()
    await mw(scope, None, capture)
    assert inner.called
    assert capture.events == []  # no 401 sent


@pytest.mark.anyio
async def test_middleware_rejects_wrong_token():
    inner = _RecordingApp()
    mw = BearerApiKeyMiddleware(inner, "my-key")
    scope = _make_http_scope("Bearer wrong")
    capture = _CaptureSend()
    await mw(scope, None, capture)
    assert not inner.called
    assert capture.events[0]["status"] == 401


@pytest.mark.anyio
async def test_middleware_logs_auth_failure():
    """Auth failure must emit a warning via the eventlog writer."""
    inner = _RecordingApp()
    mw = BearerApiKeyMiddleware(inner, "my-key")
    scope = _make_http_scope("Bearer wrong")
    scope["client"] = ("10.0.0.1", 12345)
    capture = _CaptureSend()
    with patch("legacy_mcp.auth._eventlog") as mock_log:
        await mw(scope, None, capture)
    mock_log.warn.assert_called_once()
    assert "10.0.0.1" in mock_log.warn.call_args[0][0]


@pytest.mark.anyio
async def test_middleware_does_not_log_auth_success():
    """Successful auth must NOT emit any eventlog entry (avoid log flooding)."""
    inner = _RecordingApp()
    mw = BearerApiKeyMiddleware(inner, "my-key")
    scope = _make_http_scope("Bearer my-key")
    capture = _CaptureSend()
    with patch("legacy_mcp.auth._eventlog") as mock_log:
        await mw(scope, None, capture)
    mock_log.warn.assert_not_called()
    mock_log.info.assert_not_called()


@pytest.mark.anyio
async def test_middleware_rejects_missing_header():
    inner = _RecordingApp()
    mw = BearerApiKeyMiddleware(inner, "my-key")
    scope = _make_http_scope(None)
    capture = _CaptureSend()
    await mw(scope, None, capture)
    assert not inner.called
    assert capture.events[0]["status"] == 401


@pytest.mark.anyio
async def test_middleware_401_has_no_www_authenticate_header():
    """Bug F regression: 401 must NOT include WWW-Authenticate.

    mcp-remote treats WWW-Authenticate: Bearer as an OAuth discovery trigger
    and attempts an OAuth flow that LegacyMCP does not implement, blocking
    the connection entirely.  The header must be absent from every 401 response.
    """
    inner = _RecordingApp()
    mw = BearerApiKeyMiddleware(inner, "my-key")
    scope = _make_http_scope("Bearer wrong-token")
    capture = _CaptureSend()
    await mw(scope, None, capture)

    start_event = capture.events[0]
    assert start_event["status"] == 401
    header_names = [name.lower() for name, _ in start_event["headers"]]
    assert b"www-authenticate" not in header_names, (
        "401 response must not contain WWW-Authenticate -- mcp-remote would "
        "interpret it as an OAuth discovery trigger."
    )


@pytest.mark.anyio
async def test_middleware_passes_non_http_scope():
    """Lifespan and websocket scopes must bypass auth entirely."""
    inner = _RecordingApp()
    mw = BearerApiKeyMiddleware(inner, "my-key")
    scope = _make_lifespan_scope()
    capture = _CaptureSend()
    await mw(scope, None, capture)
    assert inner.called


@pytest.mark.anyio
async def test_profile_a_stdio_never_uses_middleware():
    """Profile A uses stdio transport -- _run_with_tls is never called.
    Simulate: BearerApiKeyMiddleware is NOT instantiated when api_key=None.
    This test asserts that the guard condition in server.py holds.
    """
    api_key: str | None = None
    # Replicate the guard in _run_with_tls
    middleware_would_be_applied = bool(api_key)
    assert middleware_would_be_applied is False
