"""Unit tests for the shared field-normalization helpers
(legacy_mcp.tools._normalize) used across MCP tools to keep Offline Mode
(SQLite-stringified fields) and Live Mode (native bool/int fields) behaving
identically."""

from __future__ import annotations

from legacy_mcp.tools._normalize import is_admin_count_set, is_true


# ---------------------------------------------------------------------------
# is_true
# ---------------------------------------------------------------------------

class TestIsTrue:

    def test_native_true(self) -> None:
        assert is_true(True) is True

    def test_native_false(self) -> None:
        assert is_true(False) is False

    def test_string_true(self) -> None:
        assert is_true("True") is True

    def test_string_false(self) -> None:
        assert is_true("False") is False

    def test_none_is_false(self) -> None:
        assert is_true(None) is False

    def test_zero_is_false(self) -> None:
        assert is_true(0) is False

    def test_one_is_false(self) -> None:
        # 1 is neither a bool nor the string "True" -- must not be
        # mistaken for a truthy boolean field.
        assert is_true(1) is False


# ---------------------------------------------------------------------------
# is_admin_count_set
# ---------------------------------------------------------------------------

class TestIsAdminCountSet:

    def test_string_one(self) -> None:
        # Offline Mode shape: AdminCount serialized to "1" by the SQLite loader.
        assert is_admin_count_set("1") is True

    def test_string_zero(self) -> None:
        assert is_admin_count_set("0") is False

    def test_native_int_one(self) -> None:
        # Live Mode shape: native int straight from json.loads().
        assert is_admin_count_set(1) is True

    def test_native_int_zero(self) -> None:
        assert is_admin_count_set(0) is False

    def test_none_is_false(self) -> None:
        # AdminCount absent/unset -- the common case for regular accounts.
        assert is_admin_count_set(None) is False

    def test_other_int_is_false(self) -> None:
        assert is_admin_count_set(2) is False

    def test_non_numeric_string_is_false(self) -> None:
        assert is_admin_count_set("not-a-number") is False
