"""Unit tests for the list_workspaces MCP tool."""

from __future__ import annotations

from pathlib import Path

import pytest

from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation, Workspace, WorkspaceMode
from legacy_mcp.tools import workspace_info as workspace_info_module

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
def single_forest_workspace() -> Workspace:
    forest = ForestConfig(
        name="contoso.local",
        relation=ForestRelation.STANDALONE,
        file=str(FIXTURE_PATH),
    )
    ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=[forest])
    ws._init_connectors()
    return ws


@pytest.fixture(scope="module")
def multi_forest_workspace(tmp_path_factory: pytest.TempPathFactory) -> Workspace:
    # Second forest points to the same fixture — enough to test multi-entry output.
    forests = [
        ForestConfig(
            name="contoso.local",
            relation=ForestRelation.SOURCE,
            file=str(FIXTURE_PATH),
        ),
        ForestConfig(
            name="fabrikam.local",
            relation=ForestRelation.DESTINATION,
            file=str(FIXTURE_PATH),
        ),
    ]
    ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=forests)
    ws._init_connectors()
    return ws


@pytest.fixture(scope="module")
def tools_single(single_forest_workspace: Workspace) -> _MockMCP:
    mcp = _MockMCP()
    workspace_info_module.register(mcp, single_forest_workspace)
    return mcp


@pytest.fixture(scope="module")
def tools_multi(multi_forest_workspace: Workspace) -> _MockMCP:
    mcp = _MockMCP()
    workspace_info_module.register(mcp, multi_forest_workspace)
    return mcp


# ---------------------------------------------------------------------------
# list_workspaces — single forest
# ---------------------------------------------------------------------------

class TestListWorkspacesSingleForest:

    def test_returns_one_entry(self, tools_single: _MockMCP) -> None:
        result = tools_single.list_workspaces()
        assert len(result) == 1

    def test_name_field(self, tools_single: _MockMCP) -> None:
        result = tools_single.list_workspaces()
        assert result[0]["name"] == "contoso.local"

    def test_mode_field(self, tools_single: _MockMCP) -> None:
        result = tools_single.list_workspaces()
        assert result[0]["mode"] == "offline"

    def test_relation_field(self, tools_single: _MockMCP) -> None:
        result = tools_single.list_workspaces()
        assert result[0]["relation"] == "standalone"

    def test_contoso_loaded_true(self, tools_single: _MockMCP) -> None:
        result = tools_single.list_workspaces()
        assert result[0]["loaded"] is True

    def test_no_error(self, tools_single: _MockMCP) -> None:
        result = tools_single.list_workspaces()
        assert result[0]["error"] is None


# ---------------------------------------------------------------------------
# list_workspaces — missing file
# ---------------------------------------------------------------------------

class TestListWorkspacesMissingFile:

    def test_loaded_false_when_file_missing(self) -> None:
        forest = ForestConfig(
            name="ghost.local",
            relation=ForestRelation.STANDALONE,
            file="/nonexistent/path/ghost.json",
        )
        ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=[forest])
        ws._init_connectors()
        mcp = _MockMCP()
        workspace_info_module.register(mcp, ws)

        result = mcp.list_workspaces()
        assert result[0]["loaded"] is False
        assert result[0]["error"] is not None
        assert "not found" in result[0]["error"].lower() or "File not found" in result[0]["error"]


# ---------------------------------------------------------------------------
# list_workspaces — multiple forests
# ---------------------------------------------------------------------------

class TestListWorkspacesMultiForest:

    def test_returns_two_entries(self, tools_multi: _MockMCP) -> None:
        result = tools_multi.list_workspaces()
        assert len(result) == 2

    def test_names_present(self, tools_multi: _MockMCP) -> None:
        result = tools_multi.list_workspaces()
        names = [e["name"] for e in result]
        assert "contoso.local" in names
        assert "fabrikam.local" in names

    def test_relations(self, tools_multi: _MockMCP) -> None:
        result = tools_multi.list_workspaces()
        by_name = {e["name"]: e for e in result}
        assert by_name["contoso.local"]["relation"] == "source"
        assert by_name["fabrikam.local"]["relation"] == "dest"

    def test_both_loaded(self, tools_multi: _MockMCP) -> None:
        result = tools_multi.list_workspaces()
        for entry in result:
            assert entry["loaded"] is True


# ---------------------------------------------------------------------------
# reload_workspace
# ---------------------------------------------------------------------------

class TestReloadWorkspace:

    def test_reload_returns_loaded_true(self, tools_single: _MockMCP) -> None:
        """Happy path: reload succeeds and returns loaded=True with correct fields."""
        result = tools_single.reload_workspace()
        assert len(result) == 1
        entry = result[0]
        assert entry["name"] == "contoso.local"
        assert entry["mode"] == "offline"
        assert entry["relation"] == "standalone"
        assert entry["loaded"] is True
        assert entry["error"] is None

    def test_reload_clears_engine_cache(self, single_forest_workspace: Workspace) -> None:
        """reload_workspace resets _engine so JSON is re-read from disk."""
        from legacy_mcp.modes.offline import OfflineConnector

        mcp = _MockMCP()
        workspace_info_module.register(mcp, single_forest_workspace)

        # Prime the cache via list_workspaces.
        mcp.list_workspaces()
        conn = single_forest_workspace.connector("contoso.local")
        assert isinstance(conn, OfflineConnector)
        assert conn._engine is not None, "cache should be warm after list_workspaces"

        # reload_workspace must clear the engine and reload successfully.
        result = mcp.reload_workspace()
        assert result[0]["loaded"] is True
        # Engine was re-populated during the reload probe.
        assert conn._engine is not None

    def test_reload_missing_file_returns_error(self) -> None:
        """reload_workspace reports error for a missing file and sets loaded=False."""
        forest = ForestConfig(
            name="ghost.local",
            relation=ForestRelation.STANDALONE,
            file="/nonexistent/path/ghost.json",
        )
        ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=[forest])
        ws._init_connectors()
        mcp = _MockMCP()
        workspace_info_module.register(mcp, ws)

        result = mcp.reload_workspace()
        assert result[0]["loaded"] is False
        assert result[0]["error"] is not None
        assert "not found" in result[0]["error"].lower() or "File not found" in result[0]["error"]

    def test_reload_partial_failure_continues(self, tmp_path: Path) -> None:
        """A missing-file forest does not prevent valid forests from reloading."""
        forests = [
            ForestConfig(
                name="contoso.local",
                relation=ForestRelation.SOURCE,
                file=str(FIXTURE_PATH),
            ),
            ForestConfig(
                name="ghost.local",
                relation=ForestRelation.DESTINATION,
                file=str(tmp_path / "nonexistent.json"),
            ),
        ]
        ws = Workspace(mode=WorkspaceMode.OFFLINE, forests=forests)
        ws._init_connectors()
        mcp = _MockMCP()
        workspace_info_module.register(mcp, ws)

        result = mcp.reload_workspace()
        by_name = {e["name"]: e for e in result}

        assert by_name["contoso.local"]["loaded"] is True
        assert by_name["contoso.local"]["error"] is None
        assert by_name["ghost.local"]["loaded"] is False
        assert by_name["ghost.local"]["error"] is not None
