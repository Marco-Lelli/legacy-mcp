"""Shared field-normalization helpers for MCP tools.

Offline Mode stringifies every field via the SQLite loader's serializer
(storage/loader.py _serialize()). Live Mode returns native Python types
(bool, int) straight from json.loads() with no such pass. Any tool that
compares a field value must normalize through these helpers first, or the
comparison silently breaks in one of the two modes.
"""

from __future__ import annotations

from typing import Any


def is_true(val: Any) -> bool:
    """Normalize boolean fields from both Offline (string) and Live (native bool) mode."""
    if isinstance(val, bool):
        return val
    return str(val) == "True"


def is_admin_count_set(val: Any) -> bool:
    """Normalize AdminCount (int-like flag, not boolean) from both modes.

    Offline Mode serializes AdminCount to the string "1"/"0" (or leaves it
    None when absent). Live Mode returns a native int (or None). AdminCount
    == 1 means the account is or was SDProp-protected (privileged group
    membership).
    """
    if val is None:
        return False
    try:
        return int(val) == 1
    except (TypeError, ValueError):
        return False
