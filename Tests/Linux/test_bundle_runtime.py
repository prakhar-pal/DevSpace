"""Check that a relocated Swift GTK/VTE bundle resolves its native runtime."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PREFIX = Path(os.environ.get("DEVSPACE_TEST_FRONTEND_PREFIX", ROOT / "build/linux-dev"))
RUNTIME = Path(os.environ.get("DEVSPACE_TEST_SWIFT_RUNTIME", "/nonexistent/swift-runtime"))


@unittest.skipUnless((PREFIX / "bin/DevSpaceLinuxApp").is_file()
                     and (PREFIX / "bin/DevSpaceLinuxBackend").is_file()
                     and (RUNTIME / "libswiftCore.so").is_file(), "build the native Linux artifacts first")
class BundleRuntimeTests(unittest.TestCase):
    def test_relocated_native_bundle_loads_swift_and_system_gtk_vte(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".tmp") as temporary:
            directory = Path(temporary)
            output = directory / "original bundle"
            result = subprocess.run([sys.executable, str(ROOT / "scripts/assemble-linux.py"),
                "--frontend", str(PREFIX), "--backend", str(PREFIX / "bin/DevSpaceLinuxBackend"),
                "--swift-runtime", str(RUNTIME), "--icu-license", str(ROOT / "LICENSES/ICU-76.1.txt"),
                "--channel", "development", "--output", str(output)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            moved = directory / "relocated bundle α"
            output.rename(moved)

            env = dict(os.environ, PATH="/usr/bin:/bin", XDG_CONFIG_HOME=str(directory / "config"))
            env.pop("LD_LIBRARY_PATH", None)
            env.pop("LD_PRELOAD", None)
            env["LD_LIBRARY_PATH"] = str(moved / "lib")
            app = subprocess.run(["ldd", str(moved / "bin/DevSpaceDev")], env=env, cwd=directory,
                                capture_output=True, text=True, check=True)
            self.assertNotIn("not found", app.stdout)
            self.assertIn(str(moved / "lib/libswiftCore.so"), app.stdout)
            self.assertIn("libgtk-4.so", app.stdout)
            self.assertIn("libvte-2.91-gtk4.so", app.stdout)
            self.assertFalse((moved / "share/ghostty").exists())

            backend = moved / "bin/DevSpaceDevBackend"
            linked = subprocess.run(["ldd", str(backend)], env=env, cwd=directory,
                                    capture_output=True, text=True, check=True)
            self.assertNotIn("not found", linked.stdout)
            self.assertNotIn("swift-local", linked.stdout)
            self.assertIn(str(moved / "lib/libswiftCore.so"), linked.stdout)
            requests = [{"version": 1, "id": "1", "kind": "handshake", "payload": {}},
                        {"version": 1, "id": "2", "kind": "shutdown", "payload": {}}]
            result = subprocess.run([str(backend), "--channel", "development", "--notify-port", "0"],
                input="".join(json.dumps(request) + "\n" for request in requests),
                cwd=directory, env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([json.loads(line)["kind"] for line in result.stdout.splitlines()],
                             ["ready", "stopped"])


if __name__ == "__main__":
    unittest.main()
