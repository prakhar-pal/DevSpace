"""The host-test recorder must preserve real backend shutdown semantics."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BACKEND = Path(os.environ.get(
    "DEVSPACE_TEST_BACKEND", ROOT / "build/linux-dev/bin/DevSpaceLinuxBackend"
))


@unittest.skipUnless(BACKEND.is_file(), "build the Swift backend first")
class HostRecorderTests(unittest.TestCase):
    def test_isolated_host_run_keeps_real_notification_token(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".tmp") as temporary:
            directory = Path(temporary)
            original = directory / "real-config/devspace/notify-token"
            original.parent.mkdir(parents=True)
            token = b"0123456789abcdef0123456789abcdef"
            original.write_bytes(token)
            original.chmod(0o600)
            isolated = directory / "isolated-config"
            env = dict(os.environ, DEVSPACE_HOST_BACKEND=str(BACKEND),
                       DEVSPACE_TEST_EVENTS=str(directory / "events.jsonl"),
                       DEVSPACE_HOST_CONFIG_HOME=str(directory / "real-config"),
                       XDG_CONFIG_HOME=str(isolated))
            requests = [{"version": 1, "id": "1", "kind": "handshake"},
                        {"version": 1, "id": "2", "kind": "shutdown"}]
            result = subprocess.run([str(ROOT / "Tests/Linux/fixtures/host_backend.py"),
                                     "--channel", "development", "--notify-port", "0"],
                                    input="".join(json.dumps(row) + "\n" for row in requests),
                                    env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            copied = isolated / "devspace/notify-token"
            self.assertEqual(copied.read_bytes(), token)
            self.assertEqual(copied.stat().st_mode & 0o777, 0o600)
            self.assertEqual(original.read_bytes(), token)

    def test_frontend_can_close_response_pipe_during_shutdown(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".tmp") as temporary:
            log = Path(temporary) / "events.jsonl"
            env = dict(os.environ, DEVSPACE_HOST_BACKEND=str(BACKEND), DEVSPACE_TEST_EVENTS=str(log))
            process = subprocess.Popen([str(ROOT / "Tests/Linux/fixtures/host_backend.py"),
                                        "--channel", "development"], env=env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
            try:
                process.stdin.write(json.dumps({"version": 1, "id": "1", "kind": "handshake", "payload": {}}) + "\n")
                process.stdin.flush()
                self.assertEqual(json.loads(process.stdout.readline())["kind"], "ready")
                process.stdout.close()
                process.stdin.write(json.dumps({"version": 1, "id": "2", "kind": "shutdown", "payload": {}}) + "\n")
                process.stdin.flush()
                process.wait(timeout=5)
                error = process.stderr.read()
                self.assertEqual(process.returncode, 0, error)
                self.assertNotIn("BrokenPipeError", error)
                records = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual([row["frame"]["kind"] for row in records if row["direction"] == "event"],
                                 ["ready", "stopped"])
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=3)
                process.stdin.close()
                process.stderr.close()

    def test_teardown_can_remove_trace_path_before_backend_finishes(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".tmp") as temporary:
            log = Path(temporary) / "events.jsonl"
            env = dict(os.environ, DEVSPACE_HOST_BACKEND=str(BACKEND), DEVSPACE_TEST_EVENTS=str(log))
            process = subprocess.Popen([str(ROOT / "Tests/Linux/fixtures/host_backend.py"),
                                        "--channel", "development"], env=env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
            try:
                process.stdin.write(json.dumps({"version": 1, "id": "1", "kind": "handshake", "payload": {}}) + "\n")
                process.stdin.flush()
                self.assertEqual(json.loads(process.stdout.readline())["kind"], "ready")
                log.unlink()
                Path(temporary).rmdir()
                output, error = process.communicate(json.dumps({"version": 1, "id": "2", "kind": "shutdown", "payload": {}}) + "\n", timeout=5)
                self.assertEqual(process.returncode, 0, error)
                self.assertEqual([json.loads(line)["kind"] for line in output.splitlines()], ["stopped"])
                self.assertNotIn("Traceback", error)
            finally:
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=3)

    def test_backend_shutdown_exits_recorder_without_waiting_for_frontend_eof(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".tmp") as temporary:
            log = Path(temporary) / "events.jsonl"
            env = dict(os.environ, DEVSPACE_HOST_BACKEND=str(BACKEND), DEVSPACE_TEST_EVENTS=str(log))
            process = subprocess.Popen([str(ROOT / "Tests/Linux/fixtures/host_backend.py"),
                                        "--channel", "development"], env=env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
            try:
                requests = [{"version": 1, "id": "1", "kind": "handshake", "payload": {}},
                            {"version": 1, "id": "2", "kind": "shutdown", "payload": {}}]
                process.stdin.write("".join(json.dumps(request) + "\n" for request in requests))
                process.stdin.flush()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.fail("recorder must exit when its backend exits, even with frontend stdin open")
                output, error = process.communicate(timeout=3)
                self.assertEqual(process.returncode, 0, error)
                self.assertEqual([json.loads(line)["kind"] for line in output.splitlines()], ["ready", "stopped"])
                records = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual([row["frame"] for row in records if row["direction"] == "request"], requests)
                self.assertEqual([row["frame"]["kind"] for row in records if row["direction"] == "event"],
                                 ["ready", "stopped"])
            finally:
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=3)
