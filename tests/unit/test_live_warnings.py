"""Unit tests for warning surfacing in LiveConnector.query_with_warnings() /
query_page() (task #141).

Covers the hybrid design confirmed by Marco: small/bounded warnings reach
the tool's JSON response verbatim; the one genuinely unbounded call site
(group_members's per-group failures) is aggregate-only in JSON; every
warning, filtered or not, reaches EventLog in full.
"""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from legacy_mcp.modes.live import LiveConnector
from legacy_mcp.workspace.workspace import ForestConfig, ForestRelation


def _clixml_bytes(*, warnings: list[str] | None = None) -> bytes:
    parts = [
        "#< CLIXML",
        '<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">',
    ]
    for w in warnings or []:
        parts.append(f'<S S="warning">{w}</S>')
    parts.append("</Objs>")
    return "\n".join(parts).encode("utf-8")


@pytest.fixture
def forest() -> ForestConfig:
    return ForestConfig(
        name="contoso.local",
        relation=ForestRelation.STANDALONE,
        dc="dc01.contoso.local",
    )


@pytest.fixture
def connector(forest: ForestConfig) -> LiveConnector:
    return LiveConnector(forest)


def _mock_subprocess(stdout: bytes, stderr: bytes, returncode: int = 0) -> MagicMock:
    return MagicMock(returncode=returncode, stdout=stdout, stderr=stderr)


# ---------------------------------------------------------------------------
# query_with_warnings -- bounded/aggregate warnings pass through unchanged
# ---------------------------------------------------------------------------

class TestQueryWithWarningsBounded:

    def test_no_warnings_returns_empty_list(self, connector: LiveConnector) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = _mock_subprocess(b"[]", _clixml_bytes())
            rows, warnings = connector.query_with_warnings("groups")
        assert rows == []
        assert warnings == []

    def test_single_aggregate_warning_included_verbatim(self, connector: LiveConnector) -> None:
        msg = "userAccountControl not available for 11018 users out of 11105 collected"
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = _mock_subprocess(b"[]", _clixml_bytes(warnings=[msg]))
            rows, warnings = connector.query_with_warnings("users")
        assert warnings == [msg]

    def test_privileged_accounts_per_group_warnings_included_bounded_case(
        self, connector: LiveConnector
    ) -> None:
        # privileged_accounts's per-group failure warning has the SAME text
        # shape as group_members's ("Group 'X' not enumerated: ..."), but
        # is bounded to the 8 built-in privileged groups -- must NOT be
        # filtered here, only for section == "group_members".
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = _mock_subprocess(
                b"[]",
                _clixml_bytes(warnings=["Group 'Domain Admins' not enumerated: timeout"]),
            )
            rows, warnings = connector.query_with_warnings("privileged_accounts")
        assert warnings == ["Group 'Domain Admins' not enumerated: timeout"]


# ---------------------------------------------------------------------------
# query_with_warnings -- group_members's unbounded per-group case
# ---------------------------------------------------------------------------

class TestQueryWithWarningsGroupMembersUnbounded:

    def test_per_group_failure_excluded_from_json_warnings(
        self, connector: LiveConnector
    ) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = _mock_subprocess(
                b"[]",
                _clixml_bytes(warnings=["Group 'HelpDesk' not enumerated: Connection refused"]),
            )
            rows, warnings = connector.query_with_warnings("group_members")
        assert warnings == []

    def test_many_per_group_failures_all_excluded(self, connector: LiveConnector) -> None:
        # The realistic worst case this task is about: dozens/hundreds of
        # group failures across a large domain must not flood the JSON.
        per_group = [f"Group 'Group{i}' not enumerated: error" for i in range(50)]
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = _mock_subprocess(b"[]", _clixml_bytes(warnings=per_group))
            rows, warnings = connector.query_with_warnings("group_members")
        assert warnings == []

    def test_aggregate_summary_survives_alongside_suppressed_per_group_lines(
        self, connector: LiveConnector
    ) -> None:
        # group_members's own script emits per-group lines AND a real
        # aggregate summary in the same run (lines 840 and 849 in live.py).
        # Only the aggregate one should reach JSON.
        per_group = ["Group 'A' not enumerated: err", "Group 'B' not enumerated: err"]
        aggregate = "2 groups not enumerated due to a read error -- see the preceding WARN lines"
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = _mock_subprocess(
                b"[]", _clixml_bytes(warnings=[*per_group, aggregate])
            )
            rows, warnings = connector.query_with_warnings("group_members")
        assert warnings == [aggregate]

    def test_unresolvable_members_aggregate_line_also_survives(
        self, connector: LiveConnector
    ) -> None:
        # A DIFFERENT aggregate line in the same section (unresolvable
        # members, not group enumeration failures) -- must also pass
        # through unfiltered, it doesn't match the per-group pattern at all.
        msg = "12 unresolvable members across 3 groups (orphaned SID / removed object / external principal)"
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = _mock_subprocess(b"[]", _clixml_bytes(warnings=[msg]))
            rows, warnings = connector.query_with_warnings("group_members")
        assert warnings == [msg]


# ---------------------------------------------------------------------------
# query_page -- "warnings" key presence/absence in the paginated dict
# ---------------------------------------------------------------------------

class TestQueryPageWarningsField:

    def test_warnings_key_absent_when_no_warnings(self, connector: LiveConnector) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = _mock_subprocess(b"[]", _clixml_bytes())
            result = connector.query_page("groups")
        assert "warnings" not in result
        assert set(result.keys()) == {"items", "total", "offset", "limit", "has_more"}

    def test_warnings_key_present_and_correct_when_warnings_exist(
        self, connector: LiveConnector
    ) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = _mock_subprocess(
                b"[]", _clixml_bytes(warnings=["Schema extensions: 650 found, truncated to 500"])
            )
            result = connector.query_page("schema")
        assert result["warnings"] == ["Schema extensions: 650 found, truncated to 500"]

    def test_group_members_query_page_never_exposes_per_group_text(
        self, connector: LiveConnector
    ) -> None:
        per_group = [f"Group 'G{i}' not enumerated: err" for i in range(20)]
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = _mock_subprocess(b"[]", _clixml_bytes(warnings=per_group))
            result = connector.query_page("group_members")
        assert "warnings" not in result

    def test_query_returns_bare_list_without_warnings_attached(
        self, connector: LiveConnector
    ) -> None:
        # query() (used by get_privileged_groups, etc.) stays a bare list --
        # no behavior change for the ~20 other tools that use it.
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run:
            mock_run.return_value = _mock_subprocess(
                b'[{"a": 1}]', _clixml_bytes(warnings=["some warning"])
            )
            result = connector.query("groups")
        assert result == [{"a": 1}]
        assert isinstance(result, list)


# ---------------------------------------------------------------------------
# EventLog -- every warning reaches it, regardless of JSON filtering
# ---------------------------------------------------------------------------

class TestEventLogCoverage:

    def test_json_included_warning_also_reaches_eventlog(
        self, connector: LiveConnector
    ) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run, \
             patch("legacy_mcp.modes.live.eventlog.warn") as mock_warn:
            mock_run.return_value = _mock_subprocess(
                b"[]", _clixml_bytes(warnings=["aggregate warning text"])
            )
            connector.query_page("schema")
        mock_warn.assert_called_once()
        assert "aggregate warning text" in mock_warn.call_args.args[0]

    def test_json_excluded_group_members_warnings_still_reach_eventlog(
        self, connector: LiveConnector
    ) -> None:
        # The whole point of "no exception, all 12 to EventLog": even
        # though the per-group text is filtered out of the JSON response,
        # it must not be lost -- it has to be in EventLog.
        per_group = ["Group 'A' not enumerated: err", "Group 'B' not enumerated: err"]
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run, \
             patch("legacy_mcp.modes.live.eventlog.warn") as mock_warn:
            mock_run.return_value = _mock_subprocess(b"[]", _clixml_bytes(warnings=per_group))
            rows, warnings = connector.query_with_warnings("group_members")

        assert warnings == []  # confirmed excluded from JSON
        assert mock_warn.call_count == 2  # but both still logged
        logged_messages = [c.args[0] for c in mock_warn.call_args_list]
        assert any("Group 'A' not enumerated" in m for m in logged_messages)
        assert any("Group 'B' not enumerated" in m for m in logged_messages)

    def test_eventlog_message_includes_forest_and_section(
        self, connector: LiveConnector
    ) -> None:
        with patch("legacy_mcp.modes.live.subprocess.run") as mock_run, \
             patch("legacy_mcp.modes.live.eventlog.warn") as mock_warn:
            mock_run.return_value = _mock_subprocess(b"[]", _clixml_bytes(warnings=["hello"]))
            connector.query_page("schema")
        logged = mock_warn.call_args.args[0]
        assert "contoso.local" in logged
        assert "schema" in logged
