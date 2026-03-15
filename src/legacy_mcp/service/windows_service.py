"""Windows Service wrapper for LegacyMCP.

Installation (run as Administrator):
  python -m legacy_mcp.service.windows_service install
  python -m legacy_mcp.service.windows_service start
  python -m legacy_mcp.service.windows_service stop
  python -m legacy_mcp.service.windows_service remove
"""

from __future__ import annotations

import sys
import threading

SERVICE_NAME = "LegacyMCP"
SERVICE_DISPLAY_NAME = "LegacyMCP — AD MCP Server"
SERVICE_DESCRIPTION = "Active Directory MCP Server for AI-powered assessment"


def _require_win32() -> None:
    if sys.platform != "win32":
        raise RuntimeError("Windows Service is only supported on Windows.")
    try:
        import win32serviceutil  # noqa: F401
    except ImportError:
        raise ImportError("pywin32 is required. Install it with: pip install pywin32")


class LegacyMCPService:
    """Windows Service host for LegacyMCP."""

    def __init__(self) -> None:
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self, config_path: str = "config/config.yaml") -> None:
        from legacy_mcp.server import create_server
        from legacy_mcp.eventlog import writer

        writer.info(f"Service starting — config: {config_path}")
        mcp = create_server(config_path)

        self._thread = threading.Thread(target=mcp.run, daemon=True)
        self._thread.start()
        writer.info("Service started.")

    def stop(self) -> None:
        from legacy_mcp.eventlog import writer
        writer.info("Service stopping.")
        self._stop_event.set()


def _build_win32_service_class():
    """Dynamically build a win32serviceutil.ServiceFramework subclass."""
    _require_win32()
    import win32serviceutil
    import win32service
    import win32event

    class _Win32Service(win32serviceutil.ServiceFramework):
        _svc_name_ = SERVICE_NAME
        _svc_display_name_ = SERVICE_DISPLAY_NAME
        _svc_description_ = SERVICE_DESCRIPTION

        def __init__(self, args):
            super().__init__(args)
            self._stop_event = win32event.CreateEvent(None, 0, 0, None)
            self._service = LegacyMCPService()

        def SvcStop(self):
            self.ReportServiceStatus(win32service.SERVICE_STOP_PENDING)
            self._service.stop()
            win32event.SetEvent(self._stop_event)

        def SvcDoRun(self):
            self._service.start()
            win32event.WaitForSingleObject(self._stop_event, win32event.INFINITE)

    return _Win32Service


if __name__ == "__main__":
    _require_win32()
    import win32serviceutil
    svc_class = _build_win32_service_class()
    win32serviceutil.HandleCommandLine(svc_class)
