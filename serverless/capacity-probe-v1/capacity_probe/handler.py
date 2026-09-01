from __future__ import annotations

import os
import re
import socket
import subprocess
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping


PROBE_NAME = "SERVERLESS_CAPACITY_PROBE_V1"
WORKER_STARTUP_TIMESTAMP = datetime.now(timezone.utc)
WORKER_STARTUP_MONOTONIC = time.monotonic()
_COLD_START_LOCK = threading.Lock()
_COLD_START_DURATION_MS: float | None = None


def _utc(value: datetime | None = None) -> str:
    return (value or datetime.now(timezone.utc)).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _validate(job: Mapping[str, Any]) -> None:
    request = job.get("input")
    if not isinstance(request, dict):
        raise ValueError("input must be an object")
    if set(request) != {"schema_version", "probe", "nonce"}:
        raise ValueError("input must contain exactly schema_version, probe, and nonce")
    if request["schema_version"] != 1 or request["probe"] != PROBE_NAME:
        raise ValueError("unsupported capacity probe request")
    if not isinstance(request["nonce"], str) or not 8 <= len(request["nonce"]) <= 128:
        raise ValueError("nonce must be an 8-128 character string")


def _command(args: list[str]) -> str:
    completed = subprocess.run(args, capture_output=True, text=True, timeout=10, check=True)
    return completed.stdout


def _proc_cpu_model(read_text: Callable[[str], str]) -> str | None:
    try:
        for line in read_text("/proc/cpuinfo").splitlines():
            if line.lower().startswith("model name"):
                return line.split(":", 1)[1].strip()
    except (OSError, IndexError):
        pass
    return None


def _proc_memory(read_text: Callable[[str], str]) -> tuple[int | None, int | None]:
    try:
        values: dict[str, int] = {}
        for line in read_text("/proc/meminfo").splitlines():
            name, value = line.split(":", 1)
            values[name] = int(value.strip().split()[0]) * 1024
        return values.get("MemTotal"), values.get("MemAvailable")
    except (OSError, ValueError, IndexError):
        return None, None


def _gpu(command: Callable[[list[str]], str], environ: Mapping[str, str]) -> tuple[str | None, dict[str, Any], dict[str, int | None]]:
    cuda: dict[str, Any] = {
        "available": False,
        "container_runtime_version": environ.get("CUDA_VERSION"),
        "driver_supported_version": None,
        "driver_version": None,
    }
    vram: dict[str, int | None] = {"total_bytes": None, "free_bytes": None}
    try:
        query = command([
            "nvidia-smi",
            "--query-gpu=name,memory.total,memory.free,driver_version",
            "--format=csv,noheader,nounits",
        ]).splitlines()[0]
        name, total_mib, free_mib, driver = [part.strip() for part in query.split(",", 3)]
        banner = command(["nvidia-smi"])
        match = re.search(r"CUDA Version:\s*([0-9.]+)", banner)
        cuda.update({
            "available": True,
            "driver_supported_version": match.group(1) if match else None,
            "driver_version": driver,
        })
        vram = {
            "total_bytes": int(float(total_mib) * 1024 * 1024),
            "free_bytes": int(float(free_mib) * 1024 * 1024),
        }
        return name, cuda, vram
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return None, cuda, vram


def collect(
    *,
    environ: Mapping[str, str] = os.environ,
    command: Callable[[list[str]], str] = _command,
    read_text: Callable[[str], str] = lambda path: Path(path).read_text(encoding="utf-8"),
    now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
    monotonic: Callable[[], float] = time.monotonic,
) -> dict[str, Any]:
    global _COLD_START_DURATION_MS
    with _COLD_START_LOCK:
        if _COLD_START_DURATION_MS is None:
            _COLD_START_DURATION_MS = round(max(0.0, monotonic() - WORKER_STARTUP_MONOTONIC) * 1000, 3)
        cold_start = _COLD_START_DURATION_MS
    hostname = socket.gethostname()
    gpu_name, cuda, vram = _gpu(command, environ)
    ram_total, ram_available = _proc_memory(read_text)
    worker_id = environ.get("RUNPOD_WORKER_ID") or environ.get("RUNPOD_POD_ID") or environ.get("RUNPOD_ID") or hostname
    return {
        "worker_id": worker_id,
        "actual_gpu_model": gpu_name,
        "cuda": cuda,
        "vram": vram,
        "cpu": {"logical_cores": os.cpu_count(), "model": _proc_cpu_model(read_text)},
        "ram": {"total_bytes": ram_total, "available_bytes": ram_available},
        "hostname": hostname,
        "worker_startup_timestamp": _utc(WORKER_STARTUP_TIMESTAMP),
        "handler_execution_timestamp": _utc(now()),
        "cold_start_duration_ms": cold_start,
    }


def handler(job: Mapping[str, Any]) -> dict[str, Any]:
    _validate(job)
    return collect()
