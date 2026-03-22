"""SQLite query helpers for Offline Mode."""

from __future__ import annotations

import json
import sqlite3
from typing import Any


class QueryEngine:
    """Wraps a SQLite connection and provides typed query helpers."""

    def __init__(self, db: sqlite3.Connection, source: str) -> None:
        self.db = db
        self.source = source  # forest name — used for multi-scope tracking

    def query(self, section: str, **filters: Any) -> list[dict[str, Any]]:
        """Return all rows from a section, optionally filtered."""
        try:
            cursor = self.db.execute(f'SELECT * FROM "{section}"')
        except sqlite3.OperationalError:
            return []

        rows = [dict(row) for row in cursor.fetchall()]
        rows = _deserialize_json_columns(rows)

        for key, value in filters.items():
            rows = [r for r in rows if str(r.get(key, "")).lower() == str(value).lower()]

        return rows

    def query_page(
        self,
        section: str,
        offset: int = 0,
        limit: int = 200,
        **filters: Any,
    ) -> dict[str, Any]:
        """Return a paginated page from a section, optionally filtered.

        Returns:
            {
                "items":    list of dicts for this page,
                "total":    total matching rows (before pagination),
                "offset":   current offset,
                "limit":    current limit,
                "has_more": whether more rows exist after this page,
            }
        """
        try:
            cursor = self.db.execute(f'SELECT * FROM "{section}"')
        except sqlite3.OperationalError:
            return {
                "items": [],
                "total": 0,
                "offset": offset,
                "limit": limit,
                "has_more": False,
            }

        rows = [dict(row) for row in cursor.fetchall()]
        rows = _deserialize_json_columns(rows)

        for key, value in filters.items():
            rows = [r for r in rows if str(r.get(key, "")).lower() == str(value).lower()]

        total = len(rows)
        page = rows[offset : offset + limit]

        return {
            "items":    page,
            "total":    total,
            "offset":   offset,
            "limit":    limit,
            "has_more": offset + len(page) < total,
        }

    def count(self, section: str) -> int:
        try:
            cursor = self.db.execute(f'SELECT COUNT(*) FROM "{section}"')
            return cursor.fetchone()[0]
        except sqlite3.OperationalError:
            return 0

    def tables(self) -> list[str]:
        cursor = self.db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        )
        return [row[0] for row in cursor.fetchall()]


def _deserialize_json_columns(rows: list[dict]) -> list[dict]:
    result = []
    for row in rows:
        deserialized = {}
        for key, value in row.items():
            if isinstance(value, str) and value.startswith(("{", "[")):
                try:
                    deserialized[key] = json.loads(value)
                except json.JSONDecodeError:
                    deserialized[key] = value
            else:
                deserialized[key] = value
        result.append(deserialized)
    return result
