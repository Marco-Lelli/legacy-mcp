"""In-memory job store for background snapshot jobs.

Job state is held in memory only -- it is lost on server restart by design.
"""

from __future__ import annotations

import threading
from datetime import datetime, timezone


_lock = threading.Lock()
_jobs: dict[str, dict] = {}


def create_job(job_id: str, forest_name: str, total_steps: int) -> None:
    with _lock:
        _jobs[job_id] = {
            "status": "running",
            "forest_name": forest_name,
            "current_step": None,
            "step_index": 0,
            "total_steps": total_steps,
            "file_path": None,
            "error": None,
            "sections_collected": None,
            "sections_failed": None,
            "started_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "completed_at": None,
        }


def update_job_step(job_id: str, step_name: str, step_index: int) -> None:
    with _lock:
        job = _jobs.get(job_id)
        if job is not None:
            job["current_step"] = step_name
            job["step_index"] = step_index


def complete_job(
    job_id: str,
    file_path: str,
    sections_collected: int,
    sections_failed: list[str],
) -> None:
    with _lock:
        job = _jobs.get(job_id)
        if job is not None:
            job["status"] = "completed"
            job["file_path"] = file_path
            job["sections_collected"] = sections_collected
            job["sections_failed"] = sections_failed
            job["completed_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")


def fail_job(job_id: str, error_message: str) -> None:
    with _lock:
        job = _jobs.get(job_id)
        if job is not None:
            job["status"] = "failed"
            job["error"] = error_message
            job["completed_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")


def get_job(job_id: str) -> dict | None:
    with _lock:
        job = _jobs.get(job_id)
        return dict(job) if job is not None else None
