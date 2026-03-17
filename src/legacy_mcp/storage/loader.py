"""JSON → SQLite loader for Offline Mode."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path


# Sections expected in the collector JSON output.
KNOWN_SECTIONS = [
    "forest",
    "domains",
    "dcs",
    "sysvol",
    "sites",
    "site_links",
    "users",
    "groups",
    "ous",
    "gpos",
    "trusts",
    "fgpp",
    "dns",
    "pki",
    "schema",
    "eventlog_config",
]


class JsonLoader:
    """Loads a collector JSON file into an in-memory SQLite database."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> sqlite3.Connection:
        with self.path.open(encoding="utf-8-sig") as fh:
            data = json.load(fh)

        db = sqlite3.connect(":memory:")
        db.row_factory = sqlite3.Row

        for section in KNOWN_SECTIONS:
            rows = data.get(section)
            if not rows:
                continue
            if isinstance(rows, dict):
                rows = [rows]
            _create_and_insert(db, section, rows)

        db.commit()
        return db


def _create_and_insert(
    db: sqlite3.Connection, table: str, rows: list[dict]
) -> None:
    if not rows:
        return

    columns = list(rows[0].keys())
    col_defs = ", ".join(f'"{c}" TEXT' for c in columns)
    db.execute(f'CREATE TABLE IF NOT EXISTS "{table}" ({col_defs})')

    placeholders = ", ".join("?" for _ in columns)
    for row in rows:
        values = [_serialize(row.get(c)) for c in columns]
        db.execute(f'INSERT INTO "{table}" VALUES ({placeholders})', values)


def _serialize(value: object) -> str | None:
    if value is None:
        return None
    if isinstance(value, (dict, list)):
        return json.dumps(value)
    return str(value)
