"""Compile and exercise the Swift Linux backend protocol client."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LinuxBackendClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler = os.environ.get("DEVSPACE_SWIFTC") or shutil.which("swiftc")
        if not cls.compiler:
            raise unittest.SkipTest("Swift compiler is not installed")
        cls.temporary = tempfile.TemporaryDirectory(dir=ROOT / ".tmp")
        cls.build = Path(cls.temporary.name)
        core = subprocess.run([
            cls.compiler, "-emit-library", "-emit-module", "-module-name", "DevSpaceCore",
            "-emit-module-path", str(cls.build / "DevSpaceCore.swiftmodule"),
            "-module-cache-path", str(cls.build / "core-module-cache"),
            str(ROOT / "Sources/Core/BackendProtocol.swift"),
            "-o", str(cls.build / "libDevSpaceCore.so"),
        ], cwd=ROOT, capture_output=True, text=True)
        if core.returncode:
            raise AssertionError(core.stderr)
        app = subprocess.run([
            cls.compiler, "-I", str(cls.build), "-L", str(cls.build), "-lDevSpaceCore",
            "-Xlinker", "-rpath", "-Xlinker", str(cls.build),
            "-module-cache-path", str(cls.build / "app-module-cache"),
            str(ROOT / "Sources/LinuxApp/BackendClient.swift"),
            str(ROOT / "Tests/LinuxApp/BackendClientTests.swift"),
            "-o", str(cls.build / "backend-client-tests"),
        ], cwd=ROOT, capture_output=True, text=True)
        if app.returncode:
            raise AssertionError(app.stderr)

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "temporary"):
            cls.temporary.cleanup()

    def run_peer(self, mode, expected):
        result = subprocess.run([
            str(self.build / "backend-client-tests"),
            shutil.which("python3") or "/usr/bin/python3",
            str(ROOT / "Tests/Linux/fixtures/backend_protocol_peer.py"),
            mode,
        ], capture_output=True, text=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(expected, result.stdout)

    def test_fragmented_handshake_multiple_frames_and_orderly_shutdown(self):
        self.run_peer("normal", "fragmented=ok multi-frame=ok handshake=ok shutdown=ok")

    def test_malformed_and_oversized_frames_are_rejected(self):
        for mode in ("malformed", "oversized", "wrong-channel"):
            with self.subTest(mode=mode):
                self.run_peer(mode, f"{mode}=rejected")

    def test_unexpected_backend_disconnect_is_reported(self):
        self.run_peer("disconnect", "disconnect=rejected")

    def test_outbound_queue_and_frame_sizes_are_bounded(self):
        self.run_peer("outgoing-frame", "outgoing-frame-limit=ok")
        self.run_peer("queue", "bounded-write-queue=ok")


if __name__ == "__main__":
    unittest.main()
