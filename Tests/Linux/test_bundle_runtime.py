"""Check the assembled native executables with only bundled Swift libraries."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PREFIX = Path(os.environ.get("DEVSPACE_TEST_FRONTEND_PREFIX", ROOT / "build/linux-dev"))
RUNTIME = Path(os.environ.get("DEVSPACE_TEST_SWIFT_RUNTIME",
    ROOT / ".tmp/linux-migration/swift-local/usr/libexec/swift/lib/swift/linux"))


@unittest.skipUnless((PREFIX / "bin/DevSpaceLinuxBackend").is_file()
                     and (RUNTIME / "libswiftCore.so").is_file(), "build the native Linux artifacts first")
class BundleRuntimeTests(unittest.TestCase):
    def test_relocated_native_bundle_loads_its_libraries_and_backend_protocol(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".tmp") as temporary:
            directory = Path(temporary)
            output = directory / "original bundle"
            result = subprocess.run([sys.executable, str(ROOT / "scripts/assemble-linux.py"),
                "--frontend", str(PREFIX), "--backend", str(PREFIX / "bin/DevSpaceLinuxBackend"),
                "--swift-runtime", str(RUNTIME), "--channel", "development", "--output", str(output)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            moved = directory / "relocated bundle α"
            output.rename(moved)
            env = dict(os.environ, PATH="/usr/bin:/bin", XDG_CONFIG_HOME=str(directory / "config"))
            env.pop("LD_LIBRARY_PATH", None)
            env.pop("LD_PRELOAD", None)
            result = subprocess.run([str(moved / "bin/devspace-dev"), "+version"],
                                    cwd=directory, env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("app runtime   : .gtk", result.stdout)
            env["LD_LIBRARY_PATH"] = str(moved / "lib")
            backend = moved / "bin/DevSpaceDevBackend"
            linked = subprocess.run(["ldd", str(backend)], env=env, cwd=directory,
                                    capture_output=True, text=True, check=True)
            self.assertNotIn("not found", linked.stdout)
            self.assertNotIn("swift-local", linked.stdout)
            self.assertIn(str(moved / "lib/libswiftCore.so"), linked.stdout)
            requests = [{"version": 1, "id": "1", "kind": "handshake", "payload": {}},
                        {"version": 1, "id": "2", "kind": "shutdown", "payload": {}}]
            result = subprocess.run([str(backend), "--channel", "development"],
                input="".join(json.dumps(request) + "\n" for request in requests),
                cwd=directory, env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([json.loads(line)["kind"] for line in result.stdout.splitlines()],
                             ["ready", "stopped"])
