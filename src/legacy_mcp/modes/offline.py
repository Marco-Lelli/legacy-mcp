"""Offline Mode connector — loads JSON data into SQLite and serves queries."""

from __future__ import annotations

from pathlib import Path
from typing import Any, TYPE_CHECKING

if TYPE_CHECKING:
    from legacy_mcp.workspace.workspace import ForestConfig

from legacy_mcp.storage.loader import JsonLoader
from legacy_mcp.storage.queries import QueryEngine


class OfflineConnector:
    """Reads AD data from a JSON file exported by the PowerShell collector."""

    def __init__(self, forest: "ForestConfig") -> None:
        self.forest = forest
        self._engine: QueryEngine | None = None

    def _ensure_loaded(self) -> QueryEngine:
        if self._engine is None:
            loader = JsonLoader(Path(self.forest.file))
            db = loader.load()
            self._engine = QueryEngine(db, source=self.forest.name)
        return self._engine

    def query(self, section: str, **filters: Any) -> list[dict[str, Any]]:
        """Query a named section of the AD data."""
        engine = self._ensure_loaded()
        return engine.query(section, **filters)

    def query_page(
        self,
        section: str,
        offset: int = 0,
        limit: int = 200,
        **filters: Any,
    ) -> dict[str, Any]:
        """Return a paginated page from a section. See QueryEngine.query_page."""
        engine = self._ensure_loaded()
        return engine.query_page(section, offset=offset, limit=limit, **filters)

    def scalar(self, section: str) -> dict[str, Any] | None:
        """Return a single dict from a section (e.g. forest-level info)."""
        results = self.query(section)
        return results[0] if results else None

    @property
    def is_live(self) -> bool:
        return False
