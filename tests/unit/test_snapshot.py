"""Unit tests for the create_snapshot MCP tool."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from legacy_mcp.workspace.workspace import (
    ForestConfig,
    ForestRelation,
    Workspace,
    WorkspaceMode,
)
from legacy_mcp.tools import snapshot as snapshot_module

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

FIXTURE_PATH = Path(__file__).resolve().parents[1] / "fixtures" / "contoso-sample.json"


class _MockMCP:
    """Minimal FastMCP stand-in that captures registered tool functions."""

    def tool(self):
        def decorator(fn):
            setattr(self, fn.__name__, fn)
            return fn
        return decorator


@pytest.fixture(scope="module")
def workspace() -> Workspace:
    forest = ForestConfig(
        name="contoso.local",
        relation=ForestRelation.STANDALONE,
        file=str(FIXTURE_PATH),
    )
    ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=[forest])
    ws._init_connectors()
    return ws


@pytest.fixture(scope="module")
def tools(workspace: Workspace) -> _MockMCP:
    mcp = _MockMCP()
    snapshot_module.register(mcp, workspace)
    return mcp


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

class TestCreateSnapshotSuccess:

    def test_status_success(self, tools: _MockMCP, tmp_path: Path) -> None:
        result = tools.create_snapshot(
            "contoso.local", output_path=str(tmp_path / "snap.json")
        )
        assert result["status"] == "success"

    def test_path_matches_requested(self, tools: _MockMCP, tmp_path: Path) -> None:
        out = str(tmp_path / "snap.json")
        result = tools.create_snapshot("contoso.local", output_path=out)
        assert result["path"] == out

    def test_file_created_on_disk(self, tools: _MockMCP, tmp_path: Path) -> None:
        out = tmp_path / "snap.json"
        tools.create_snapshot("contoso.local", output_path=str(out))
        assert out.exists()

    def test_sections_collected_positive(self, tools: _MockMCP, tmp_path: Path) -> None:
        result = tools.create_snapshot(
            "contoso.local", output_path=str(tmp_path / "snap.json")
        )
        assert result["sections_collected"] > 0

    def test_sections_failed_is_empty(self, tools: _MockMCP, tmp_path: Path) -> None:
        result = tools.create_snapshot(
            "contoso.local", output_path=str(tmp_path / "snap.json")
        )
        assert result["sections_failed"] == []

    def test_encryption_field_none(self, tools: _MockMCP, tmp_path: Path) -> None:
        result = tools.create_snapshot(
            "contoso.local", output_path=str(tmp_path / "snap.json")
        )
        assert result["encryption"] == "none"

    def test_forest_field_correct(self, tools: _MockMCP, tmp_path: Path) -> None:
        result = tools.create_snapshot(
            "contoso.local", output_path=str(tmp_path / "snap.json")
        )
        assert result["forest"] == "contoso.local"

    def test_timestamp_present(self, tools: _MockMCP, tmp_path: Path) -> None:
        result = tools.create_snapshot(
            "contoso.local", output_path=str(tmp_path / "snap.json")
        )
        assert result["timestamp"]
        # Basic ISO-8601 sanity check.
        assert "T" in result["timestamp"]


# ---------------------------------------------------------------------------
# Output JSON format
# ---------------------------------------------------------------------------

class TestSnapshotOutputFormat:

    @pytest.fixture(scope="class")
    def snapshot_data(self, tmp_path_factory: pytest.TempPathFactory) -> dict:
        mcp = _MockMCP()
        forest = ForestConfig(
            name="contoso.local",
            relation=ForestRelation.STANDALONE,
            file=str(FIXTURE_PATH),
        )
        ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=[forest])
        ws._init_connectors()
        snapshot_module.register(mcp, ws)
        out = tmp_path_factory.mktemp("snap") / "contoso.json"
        mcp.create_snapshot("contoso.local", output_path=str(out))
        return json.loads(out.read_text(encoding="utf-8"))

    def test_metadata_block_present(self, snapshot_data: dict) -> None:
        assert "_metadata" in snapshot_data

    def test_metadata_generated_by(self, snapshot_data: dict) -> None:
        assert snapshot_data["_metadata"]["generated_by"] == "LegacyMCP"

    def test_metadata_forest(self, snapshot_data: dict) -> None:
        assert snapshot_data["_metadata"]["forest"] == "contoso.local"

    def test_metadata_encryption(self, snapshot_data: dict) -> None:
        assert snapshot_data["_metadata"]["encryption"] == "none"

    def test_metadata_mode(self, snapshot_data: dict) -> None:
        assert snapshot_data["_metadata"]["mode"] == "live_snapshot"

    def test_metadata_version(self, snapshot_data: dict) -> None:
        assert snapshot_data["_metadata"]["version"] == "1.0"

    def test_forest_section_is_dict(self, snapshot_data: dict) -> None:
        """Scalar section 'forest' must be a dict, not a list."""
        assert isinstance(snapshot_data["forest"], dict)

    def test_users_section_is_list(self, snapshot_data: dict) -> None:
        """List section 'users' must be a list."""
        assert isinstance(snapshot_data["users"], list)

    def test_domains_section_is_list(self, snapshot_data: dict) -> None:
        assert isinstance(snapshot_data["domains"], list)

    def test_forest_name_matches(self, snapshot_data: dict) -> None:
        assert snapshot_data["forest"]["Name"] == "contoso.local"


# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

class TestSnapshotErrors:

    def test_keyvault_returns_error(self, tools: _MockMCP, tmp_path: Path) -> None:
        result = tools.create_snapshot(
            "contoso.local",
            encryption="keyvault",
            output_path=str(tmp_path / "kv.json"),
        )
        assert result["status"] == "error"
        assert "Enterprise" in result["error"]

    def test_keyvault_sections_collected_zero(self, tools: _MockMCP, tmp_path: Path) -> None:
        result = tools.create_snapshot(
            "contoso.local",
            encryption="keyvault",
            output_path=str(tmp_path / "kv.json"),
        )
        assert result["sections_collected"] == 0

    def test_unknown_encryption_returns_error(self, tools: _MockMCP, tmp_path: Path) -> None:
        result = tools.create_snapshot(
            "contoso.local",
            encryption="aes256",
            output_path=str(tmp_path / "enc.json"),
        )
        assert result["status"] == "error"
        assert "aes256" in result["error"]

    def test_unknown_forest_returns_error(self, tools: _MockMCP, tmp_path: Path) -> None:
        result = tools.create_snapshot(
            "ghost.local",
            output_path=str(tmp_path / "ghost.json"),
        )
        assert result["status"] == "error"
        assert result["forest"] == "ghost.local"

    def test_unknown_forest_file_not_created(self, tools: _MockMCP, tmp_path: Path) -> None:
        out = tmp_path / "ghost.json"
        tools.create_snapshot("ghost.local", output_path=str(out))
        assert not out.exists()


# ---------------------------------------------------------------------------
# Graceful degradation: partial failure continues
# ---------------------------------------------------------------------------

class TestSnapshotPartialFailure:

    def test_sections_failed_reported(self, tmp_path: Path) -> None:
        """If a section raises, it ends up in sections_failed and the rest succeed."""
        from legacy_mcp.modes.offline import OfflineConnector

        forest = ForestConfig(
            name="contoso.local",
            relation=ForestRelation.STANDALONE,
            file=str(FIXTURE_PATH),
        )
        ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=[forest])
        ws._init_connectors()

        # Patch the connector so "users" always raises.
        original_query = ws.connector("contoso.local").query

        def broken_query(section: str, **kw):
            if section == "users":
                raise RuntimeError("simulated failure")
            return original_query(section, **kw)

        ws.connector("contoso.local").query = broken_query

        mcp = _MockMCP()
        snapshot_module.register(mcp, ws)
        result = mcp.create_snapshot(
            "contoso.local", output_path=str(tmp_path / "partial.json")
        )

        assert result["status"] == "success"
        assert "users" in result["sections_failed"]
        assert result["sections_collected"] > 0

    def test_partial_file_still_written(self, tmp_path: Path) -> None:
        """Snapshot file is written even when some sections fail."""
        from legacy_mcp.modes.offline import OfflineConnector

        forest = ForestConfig(
            name="contoso.local",
            relation=ForestRelation.STANDALONE,
            file=str(FIXTURE_PATH),
        )
        ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=[forest])
        ws._init_connectors()

        original_query = ws.connector("contoso.local").query

        def broken_query(section: str, **kw):
            if section == "groups":
                raise RuntimeError("simulated failure")
            return original_query(section, **kw)

        ws.connector("contoso.local").query = broken_query

        mcp = _MockMCP()
        snapshot_module.register(mcp, ws)
        out = tmp_path / "partial.json"
        mcp.create_snapshot("contoso.local", output_path=str(out))

        assert out.exists()
        data = json.loads(out.read_text(encoding="utf-8"))
        assert "_metadata" in data
        # The broken section must not appear in the output.
        assert "groups" not in data
