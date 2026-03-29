"""Unit tests for the create_snapshot, list_snapshots, and load_snapshot MCP tools."""

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

    def test_metadata_module(self, snapshot_data: dict) -> None:
        assert snapshot_data["_metadata"]["module"] == "ad-core"

    def test_metadata_forest(self, snapshot_data: dict) -> None:
        assert snapshot_data["_metadata"]["forest"] == "contoso.local"

    def test_metadata_collected_at_present(self, snapshot_data: dict) -> None:
        assert "collected_at" in snapshot_data["_metadata"]

    def test_metadata_collected_at_utc_format(self, snapshot_data: dict) -> None:
        """collected_at must be UTC ISO 8601 ending in Z."""
        assert snapshot_data["_metadata"]["collected_at"].endswith("Z")

    def test_metadata_collector_version_live(self, snapshot_data: dict) -> None:
        assert snapshot_data["_metadata"]["collector_version"].startswith("legacymcp-live-")

    def test_metadata_collected_by_present(self, snapshot_data: dict) -> None:
        assert "collected_by" in snapshot_data["_metadata"]

    def test_metadata_encryption(self, snapshot_data: dict) -> None:
        assert snapshot_data["_metadata"]["encryption"] == "none"

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


# ---------------------------------------------------------------------------
# list_snapshots
# ---------------------------------------------------------------------------

def _make_snapshot(tools: _MockMCP, directory: Path, filename: str) -> Path:
    """Helper: write a real snapshot into *directory* and return its path."""
    out = directory / filename
    tools.create_snapshot("contoso.local", output_path=str(out))
    return out


class TestListSnapshots:

    @pytest.fixture()
    def snap_dir(self, tmp_path: Path, tools: _MockMCP) -> Path:
        """A temp directory pre-populated with two snapshot files."""
        _make_snapshot(tools, tmp_path, "contoso_20250323_100000.json")
        _make_snapshot(tools, tmp_path, "contoso_20250323_110000.json")
        return tmp_path

    def test_total_matches_file_count(
        self, tools: _MockMCP, snap_dir: Path
    ) -> None:
        result = tools.list_snapshots(path=str(snap_dir))
        assert result["total"] == 2

    def test_snapshots_is_list(self, tools: _MockMCP, snap_dir: Path) -> None:
        result = tools.list_snapshots(path=str(snap_dir))
        assert isinstance(result["snapshots"], list)

    def test_path_scanned_returned(self, tools: _MockMCP, snap_dir: Path) -> None:
        result = tools.list_snapshots(path=str(snap_dir))
        assert result["path_scanned"] == str(snap_dir)

    def test_entry_fields_present(self, tools: _MockMCP, snap_dir: Path) -> None:
        result = tools.list_snapshots(path=str(snap_dir))
        for entry in result["snapshots"]:
            for key in ("path", "forest", "timestamp", "encryption",
                        "sections_collected", "size_kb", "filename"):
                assert key in entry, f"missing key: {key}"

    def test_forest_name_from_metadata(
        self, tools: _MockMCP, snap_dir: Path
    ) -> None:
        result = tools.list_snapshots(path=str(snap_dir))
        for entry in result["snapshots"]:
            assert entry["forest"] == "contoso.local"

    def test_encryption_none_for_json_files(
        self, tools: _MockMCP, snap_dir: Path
    ) -> None:
        result = tools.list_snapshots(path=str(snap_dir))
        for entry in result["snapshots"]:
            assert entry["encryption"] == "none"

    def test_sections_collected_positive(
        self, tools: _MockMCP, snap_dir: Path
    ) -> None:
        result = tools.list_snapshots(path=str(snap_dir))
        for entry in result["snapshots"]:
            assert entry["sections_collected"] > 0

    def test_size_kb_positive(self, tools: _MockMCP, snap_dir: Path) -> None:
        result = tools.list_snapshots(path=str(snap_dir))
        for entry in result["snapshots"]:
            assert entry["size_kb"] > 0

    def test_missing_directory_returns_empty(
        self, tools: _MockMCP, tmp_path: Path
    ) -> None:
        nonexistent = tmp_path / "no_such_dir"
        result = tools.list_snapshots(path=str(nonexistent))
        assert result["total"] == 0
        assert result["snapshots"] == []

    def test_dpapi_file_listed_without_decryption(
        self, tools: _MockMCP, tmp_path: Path
    ) -> None:
        """A .json.dpapi file must appear with encryption='dpapi'."""
        # Create a fake .json.dpapi file (just bytes, not real DPAPI output).
        fake = tmp_path / "contoso_20250323_120000.json.dpapi"
        fake.write_bytes(b"encrypted-blob")
        result = tools.list_snapshots(path=str(tmp_path))
        dpapi_entries = [e for e in result["snapshots"] if e["encryption"] == "dpapi"]
        assert len(dpapi_entries) == 1
        assert dpapi_entries[0]["filename"] == fake.name

    def test_non_json_files_ignored(
        self, tools: _MockMCP, snap_dir: Path
    ) -> None:
        (snap_dir / "readme.txt").write_text("ignore me")
        result = tools.list_snapshots(path=str(snap_dir))
        filenames = [e["filename"] for e in result["snapshots"]]
        assert "readme.txt" not in filenames


# ---------------------------------------------------------------------------
# load_snapshot
# ---------------------------------------------------------------------------

def _fresh_workspace() -> Workspace:
    """Return a new workspace instance (function-scoped to avoid mutation leaks)."""
    forest = ForestConfig(
        name="contoso.local",
        relation=ForestRelation.STANDALONE,
        file=str(FIXTURE_PATH),
    )
    ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=[forest])
    ws._init_connectors()
    return ws


def _fresh_tools(ws: Workspace) -> _MockMCP:
    mcp = _MockMCP()
    snapshot_module.register(mcp, ws)
    return mcp


class TestLoadSnapshot:

    @pytest.fixture()
    def snap_file(self, tmp_path: Path) -> Path:
        """A valid snapshot file produced by create_snapshot."""
        ws = _fresh_workspace()
        t = _fresh_tools(ws)
        out = tmp_path / "contoso_snap.json"
        t.create_snapshot("contoso.local", output_path=str(out))
        return out

    def test_status_success(self, snap_file: Path, tmp_path: Path) -> None:
        ws = _fresh_workspace()
        t = _fresh_tools(ws)
        result = t.load_snapshot(path=str(snap_file))
        assert result["status"] == "success"

    def test_sections_loaded_positive(self, snap_file: Path) -> None:
        ws = _fresh_workspace()
        t = _fresh_tools(ws)
        result = t.load_snapshot(path=str(snap_file))
        assert result["sections_loaded"] > 0

    def test_alias_contains_forest_name(self, snap_file: Path) -> None:
        ws = _fresh_workspace()
        t = _fresh_tools(ws)
        result = t.load_snapshot(path=str(snap_file))
        assert "contoso.local" in result["forest_alias"]

    def test_alias_contains_date(self, snap_file: Path) -> None:
        ws = _fresh_workspace()
        t = _fresh_tools(ws)
        result = t.load_snapshot(path=str(snap_file))
        # Auto-alias format: "<forest>@YYYY-MM-DD"
        assert "@" in result["forest_alias"]

    def test_custom_alias_used(self, snap_file: Path) -> None:
        ws = _fresh_workspace()
        t = _fresh_tools(ws)
        result = t.load_snapshot(path=str(snap_file), forest_alias="my-snap")
        assert result["forest_alias"] == "my-snap"

    def test_forest_added_to_workspace(self, snap_file: Path) -> None:
        ws = _fresh_workspace()
        t = _fresh_tools(ws)
        result = t.load_snapshot(path=str(snap_file), forest_alias="snap-test")
        assert "snap-test" in ws._connectors
        assert any(f.name == "snap-test" for f in ws.forests)

    def test_forest_relation_is_snapshot(self, snap_file: Path) -> None:
        from legacy_mcp.workspace.workspace import ForestRelation
        ws = _fresh_workspace()
        t = _fresh_tools(ws)
        t.load_snapshot(path=str(snap_file), forest_alias="snap-rel")
        fc = next(f for f in ws.forests if f.name == "snap-rel")
        assert fc.relation == ForestRelation.SNAPSHOT

    def test_loaded_forest_queryable(self, snap_file: Path) -> None:
        """After loading, the forest alias can be used to query data."""
        ws = _fresh_workspace()
        t = _fresh_tools(ws)
        t.load_snapshot(path=str(snap_file), forest_alias="snap-q")
        conn = ws.connector("snap-q")
        forest_info = conn.scalar("forest")
        assert forest_info is not None
        assert "Name" in forest_info

    def test_missing_file_returns_error(self, tmp_path: Path) -> None:
        ws = _fresh_workspace()
        t = _fresh_tools(ws)
        result = t.load_snapshot(path=str(tmp_path / "nonexistent.json"))
        assert result["status"] == "error"
        assert "not found" in result["message"].lower()

    def test_duplicate_alias_returns_error(self, snap_file: Path) -> None:
        ws = _fresh_workspace()
        t = _fresh_tools(ws)
        t.load_snapshot(path=str(snap_file), forest_alias="dup-alias")
        # Second load with same alias must fail.
        result = t.load_snapshot(path=str(snap_file), forest_alias="dup-alias")
        assert result["status"] == "error"
        assert "dup-alias" in result["message"]

    def test_dpapi_returns_error(self, snap_file: Path) -> None:
        ws = _fresh_workspace()
        t = _fresh_tools(ws)
        result = t.load_snapshot(path=str(snap_file), encryption="dpapi")
        assert result["status"] == "error"

    def test_unknown_encryption_returns_error(self, snap_file: Path) -> None:
        ws = _fresh_workspace()
        t = _fresh_tools(ws)
        result = t.load_snapshot(path=str(snap_file), encryption="aes256")
        assert result["status"] == "error"
        assert "aes256" in result["message"]


# ---------------------------------------------------------------------------
# Configurable snapshot_path
# ---------------------------------------------------------------------------

class TestSnapshotPathConfig:
    """snapshot_path passed to register() must be used as the default output
    directory for create_snapshot and as the default scan path for list_snapshots."""

    def test_create_snapshot_uses_configured_path(self, workspace: Workspace, tmp_path: Path) -> None:
        """create_snapshot without output_path writes to the configured snapshot_path."""
        snap_dir = tmp_path / "configured_snaps"
        mcp = _MockMCP()
        snapshot_module.register(mcp, workspace, snapshot_path=str(snap_dir))

        result = mcp.create_snapshot("contoso.local")
        assert result["status"] == "success"
        assert str(snap_dir) in result["path"]
        assert snap_dir.exists()

    def test_create_snapshot_file_created_in_configured_path(self, workspace: Workspace, tmp_path: Path) -> None:
        """The snapshot file is actually present inside the configured directory."""
        snap_dir = tmp_path / "configured_snaps"
        mcp = _MockMCP()
        snapshot_module.register(mcp, workspace, snapshot_path=str(snap_dir))

        result = mcp.create_snapshot("contoso.local")
        assert Path(result["path"]).parent == snap_dir

    def test_list_snapshots_default_uses_configured_path(self, workspace: Workspace, tmp_path: Path) -> None:
        """list_snapshots() without arguments scans the configured snapshot_path."""
        snap_dir = tmp_path / "configured_snaps"
        snap_dir.mkdir()
        mcp = _MockMCP()
        snapshot_module.register(mcp, workspace, snapshot_path=str(snap_dir))

        result = mcp.list_snapshots()
        assert result["path_scanned"] == str(snap_dir)

    def test_output_path_overrides_configured_path(self, workspace: Workspace, tmp_path: Path) -> None:
        """Explicit output_path takes precedence over the configured snapshot_path."""
        snap_dir = tmp_path / "configured_snaps"
        explicit = tmp_path / "explicit" / "snap.json"
        mcp = _MockMCP()
        snapshot_module.register(mcp, workspace, snapshot_path=str(snap_dir))

        result = mcp.create_snapshot("contoso.local", output_path=str(explicit))
        assert result["status"] == "success"
        assert result["path"] == str(explicit)
        assert not snap_dir.exists()  # configured dir never created

    def test_default_snapshot_path_used_when_not_configured(self, workspace: Workspace, tmp_path: Path) -> None:
        """When snapshot_path is None, _DEFAULT_OUTPUT_DIR is used as fallback."""
        from legacy_mcp.tools.snapshot import _DEFAULT_OUTPUT_DIR
        mcp = _MockMCP()
        snapshot_module.register(mcp, workspace)  # no snapshot_path

        result = mcp.list_snapshots()
        assert result["path_scanned"] == str(_DEFAULT_OUTPUT_DIR)
