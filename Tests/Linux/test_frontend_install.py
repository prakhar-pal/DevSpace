"""Run the actual installed frontend away from its source/build directory."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PREFIX = Path(os.environ.get("DEVSPACE_TEST_FRONTEND_PREFIX", ROOT / "build/linux-dev"))


@unittest.skipUnless((PREFIX / "bin/ghostty").is_file(), "build the Linux frontend first")
class FrontendInstallTests(unittest.TestCase):
    def test_frontend_loads_bundled_libraries_after_relocation(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".tmp") as temporary:
            directory = Path(temporary)
            installed = directory / "installed path α"
            shutil.copytree(PREFIX / "bin", installed / "bin")
            shutil.copytree(PREFIX / "lib", installed / "lib")
            environment = dict(os.environ)
            environment.pop("LD_LIBRARY_PATH", None)
            environment.pop("LD_PRELOAD", None)
            result = subprocess.run([str(installed / "bin/ghostty"), "+version"],
                                    cwd=directory, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("app runtime   : .gtk", result.stdout)

    def test_frontend_does_not_search_build_cache_for_libraries(self):
        result = subprocess.run(["readelf", "-d", str(PREFIX / "bin/ghostty")],
                                capture_output=True, text=True, check=True)
        paths = [line for line in result.stdout.splitlines() if "RUNPATH" in line or "RPATH" in line]
        self.assertTrue(paths, "the bundled dependency needs an executable-relative search path")
        self.assertTrue(any("$ORIGIN/../lib" in line for line in paths), paths)
        self.assertFalse(any(".zig-cache" in line or "zig-cache" in line for line in paths), paths)
