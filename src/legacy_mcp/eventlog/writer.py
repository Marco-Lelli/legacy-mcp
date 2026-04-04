"""Windows EventLog writer — LegacyMCP dedicated event log.

Log name  : LegacyMCP
Source    : LegacyMCP-Server
Event IDs :
  1000 — Informational: operation completed successfully
  2000 — Warning: DC unreachable (graceful degradation)
  3000 — Error: blocking failure

Registration (run once as Administrator):
  New-EventLog -LogName LegacyMCP -Source LegacyMCP-Server
"""

from __future__ import annotations

import logging
import sys

_LOG_NAME = "LegacyMCP"
_SOURCE = "LegacyMCP-Server"

_EVENT_INFO = 1000
_EVENT_WARN = 2000
_EVENT_ERROR = 3000

logger = logging.getLogger(_SOURCE)

_warned = False  # emit the registration warning at most once per process


def _write_windows_event(event_id: int, message: str, event_type: str) -> None:
    global _warned
    if sys.platform != "win32":
        return
    try:
        import win32evtlog  # noqa: F401
        import win32evtlogutil
        import win32con

        type_map = {
            "info": win32con.EVENTLOG_INFORMATION_TYPE,
            "warn": win32con.EVENTLOG_WARNING_TYPE,
            "error": win32con.EVENTLOG_ERROR_TYPE,
        }
        win32evtlogutil.ReportEvent(
            _SOURCE,
            event_id,
            eventCategory=0,
            eventType=type_map.get(event_type, win32con.EVENTLOG_INFORMATION_TYPE),
            strings=[message],
            data=None,
        )
    except Exception as e:
        if not _warned:
            _warned = True
            print(
                f"[LegacyMCP] WARNING: EventLog write failed -- "
                f"source 'LegacyMCP-Server' may not be registered. "
                f"Run scripts/Register-EventLog.ps1 as Administrator. "
                f"Error: {e}",
                file=sys.stderr,
            )


def info(message: str) -> None:
    """Log a successful operation."""
    logger.info(message)
    _write_windows_event(_EVENT_INFO, message, "info")


def warn(message: str) -> None:
    """Log a non-blocking warning."""
    logger.warning(message)
    _write_windows_event(_EVENT_WARN, message, "warn")


def warn_dc_unreachable(dc: str, detail: str = "") -> None:
    """Log a DC that could not be reached (warning, non-blocking)."""
    msg = f"DC unreachable: {dc}"
    if detail:
        msg += f" — {detail}"
    logger.warning(msg)
    _write_windows_event(_EVENT_WARN, msg, "warn")


def error(message: str) -> None:
    """Log a blocking error."""
    logger.error(message)
    _write_windows_event(_EVENT_ERROR, message, "error")
