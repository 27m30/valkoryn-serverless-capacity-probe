from __future__ import annotations

import unittest
import sys
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import patch

from capacity_probe import handler as module
from capacity_probe import entrypoint


EXPECTED_KEYS = {
    "worker_id", "actual_gpu_model", "cuda", "vram", "cpu", "ram", "hostname",
    "worker_startup_timestamp", "handler_execution_timestamp", "cold_start_duration_ms",
}


def request(extra=None):
    value = {"schema_version": 1, "probe": module.PROBE_NAME, "nonce": "0123456789abcdef"}
    if extra:
        value.update(extra)
    return {"input": value}


class CapacityProbeTests(unittest.TestCase):
    def setUp(self):
        module._COLD_START_DURATION_MS = None

    def test_gpu_response_contains_only_probe_fields(self):
        calls = iter([
            "NVIDIA L40S, 46068, 45000, 570.86.10\n",
            "NVIDIA-SMI 570.86.10 Driver Version: 570.86.10 CUDA Version: 12.8\n",
        ])
        proc = {
            "/proc/cpuinfo": "model name : Offline CPU\n",
            "/proc/meminfo": "MemTotal: 65536 kB\nMemAvailable: 32768 kB\n",
        }
        with patch.object(module.os, "cpu_count", return_value=16), patch.object(module.socket, "gethostname", return_value="probe-host"):
            result = module.collect(
                environ={"RUNPOD_WORKER_ID": "worker-123", "CUDA_VERSION": "12.8.1"},
                command=lambda _args: next(calls),
                read_text=lambda path: proc[path],
                now=lambda: datetime(2026, 8, 31, tzinfo=timezone.utc),
                monotonic=lambda: module.WORKER_STARTUP_MONOTONIC + 1.25,
            )
        self.assertEqual(EXPECTED_KEYS, set(result))
        self.assertEqual("worker-123", result["worker_id"])
        self.assertEqual("NVIDIA L40S", result["actual_gpu_model"])
        self.assertTrue(result["cuda"]["available"])
        self.assertEqual("12.8", result["cuda"]["driver_supported_version"])
        self.assertEqual(46068 * 1024 * 1024, result["vram"]["total_bytes"])
        self.assertEqual(1250.0, result["cold_start_duration_ms"])

    def test_no_gpu_is_reported_without_fabrication(self):
        def unavailable(_args):
            raise FileNotFoundError("nvidia-smi")
        result = module.collect(
            environ={},
            command=unavailable,
            read_text=lambda _path: "",
            monotonic=lambda: module.WORKER_STARTUP_MONOTONIC,
        )
        self.assertFalse(result["cuda"]["available"])
        self.assertIsNone(result["actual_gpu_model"])
        self.assertIsNone(result["vram"]["total_bytes"])

    def test_handler_rejects_extra_or_wrong_input(self):
        with self.assertRaises(ValueError):
            module.handler(request({"unexpected": True}))
        with self.assertRaises(ValueError):
            module.handler({"input": {"schema_version": 1, "probe": "wrong", "nonce": "12345678"}})

    def test_cold_start_measurement_is_stable_on_replay(self):
        first = module.collect(command=lambda _args: (_ for _ in ()).throw(FileNotFoundError()), read_text=lambda _path: "", monotonic=lambda: module.WORKER_STARTUP_MONOTONIC + 2)
        second = module.collect(command=lambda _args: (_ for _ in ()).throw(FileNotFoundError()), read_text=lambda _path: "", monotonic=lambda: module.WORKER_STARTUP_MONOTONIC + 10)
        self.assertEqual(2000.0, first["cold_start_duration_ms"])
        self.assertEqual(first["cold_start_duration_ms"], second["cold_start_duration_ms"])

    def test_entrypoint_registers_only_the_probe_handler(self):
        captured = {}
        fake_runpod = SimpleNamespace(serverless=SimpleNamespace(start=lambda configuration: captured.update(configuration)))
        with patch.dict(sys.modules, {"runpod": fake_runpod}):
            entrypoint.main()
        self.assertEqual({"handler"}, set(captured))
        self.assertIs(module.handler, captured["handler"])


if __name__ == "__main__":
    unittest.main()
