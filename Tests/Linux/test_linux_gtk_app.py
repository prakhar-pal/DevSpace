"""Compile and exercise the production Linux entry point's fail-closed channel gate."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LinuxGtkAppTests(unittest.TestCase):
    def test_invalid_or_missing_channel_fails_before_gtk_or_backend_startup(self):
        compiler = os.environ.get("DEVSPACE_SWIFTC") or shutil.which("swiftc")
        self.assertIsNotNone(compiler, "Swift compiler must be installed")
        cflags = shlex.split(subprocess.check_output(
            ["pkg-config", "--cflags", "gtk4", "vte-2.91-gtk4"], text=True
        ))
        libraries = shlex.split(subprocess.check_output(
            ["pkg-config", "--libs", "gtk4", "vte-2.91-gtk4"], text=True
        ))

        with tempfile.TemporaryDirectory(dir=ROOT / ".tmp") as temporary:
            build = Path(temporary)
            module_map = ROOT / "Tests/Linux/fixtures/CPTY.modulemap"
            cpty = subprocess.run([
                "cc", "-shared", "-fPIC", "-I", str(ROOT / "Sources/CPTY/include"),
                str(ROOT / "Sources/CPTY/cpty.c"), "-lutil", "-o", str(build / "libCPTY.so"),
            ], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(cpty.returncode, 0, cpty.stderr)
            core = subprocess.run([
                compiler, "-emit-library", "-emit-module", "-module-name", "DevSpaceCore",
                "-emit-module-path", str(build / "DevSpaceCore.swiftmodule"),
                "-module-cache-path", str(build / "core-module-cache"),
                "-Xcc", f"-fmodule-map-file={module_map}", "-I", str(ROOT / "Sources/CPTY/include"),
                *map(str, sorted((ROOT / "Sources/Core").glob("*.swift"))),
                "-L", str(build), "-lCPTY", "-lutil", "-Xlinker", "-rpath", "-Xlinker", str(build),
                "-o", str(build / "libDevSpaceCore.so"),
            ], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(core.returncode, 0, core.stderr)

            app = build / "DevSpaceLinuxApp"
            command = [
                compiler, *map(str, sorted((ROOT / "Sources/LinuxApp").glob("*.swift"))),
                "-I", str(build), "-I", str(ROOT / "Sources/CPTY/include"),
                "-I", str(ROOT / "Sources/LinuxGTK"), "-I", str(ROOT / "Sources/LinuxVTE"),
                "-Xcc", f"-fmodule-map-file={module_map}",
                "-module-cache-path", str(build / "app-module-cache"),
                "-L", str(build), "-lDevSpaceCore", "-lCPTY", "-lutil",
                "-Xlinker", "-rpath", "-Xlinker", str(build), "-o", str(app),
            ]
            for flag in cflags:
                command.extend(["-Xcc", flag])
            command.extend(libraries)
            built = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)

            environment = dict(os.environ)
            environment.pop("DEVSPACE_BUILD_CHANNEL", None)
            result = subprocess.run([str(app)], cwd=ROOT, env=environment,
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("DEVSPACE_BUILD_CHANNEL must be development or production", result.stderr)


if __name__ == "__main__":
    unittest.main()
