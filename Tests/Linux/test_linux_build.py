"""Exercise Make's Linux build orchestration with controlled compiler tools."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LinuxBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / ".tmp")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        shutil.copyfile(ROOT / "Makefile", self.directory / "Makefile")
        (self.directory / "scripts").mkdir()
        shutil.copyfile(ROOT / "scripts/assemble-linux.py", self.directory / "scripts/assemble-linux.py")
        shutil.copytree(ROOT / "Resources", self.directory / "Resources")
        self.runtime = self.directory / "runtime"
        self.runtime.mkdir()
        (self.runtime / "libswiftCore.so").write_text("controlled runtime")
        self.frontend = self.directory / "frontend"
        (self.frontend / "src").mkdir(parents=True)
        (self.frontend / "src/devspace_gtk_test.zig").touch()
        self.swift = self.directory / "swift"
        self.swift.write_text("#!/usr/bin/env python3\nfrom pathlib import Path\n"
                              "p=Path('.tmp/swift-controller-test/debug/DevSpaceLinuxBackend')\n"
                              "p.parent.mkdir(parents=True,exist_ok=True)\n"
                              "p.write_text('controlled backend artifact')\n")
        self.swift.chmod(0o755)
        self.zig = self.directory / "zig"
        self.zig.write_text("#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\n"
                            "Path('../arguments.json').write_text(json.dumps(sys.argv[1:]))\n"
                            "prefix=Path(sys.argv[sys.argv.index('--prefix')+1])\n"
                            "(prefix/'bin').mkdir(parents=True,exist_ok=True)\n"
                            "(prefix/'bin/ghostty').write_text('controlled frontend artifact')\n")
        self.zig.chmod(0o755)

    def build(self):
        return subprocess.run(["make", "linux-build-dev", f"LINUX_FRONTEND={self.frontend}",
                               f"SWIFT={self.swift}", f"ZIG={self.zig}"], cwd=self.directory,
                              capture_output=True, text=True)

    def test_build_uses_one_shared_local_cache_and_installs_backend(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads((self.directory / "arguments.json").read_text())
        self.assertIn("--cache-dir", arguments, "avoid a new compiler cache for each prepared revision")
        self.assertEqual(arguments[arguments.index("--cache-dir") + 1],
                         str(self.directory / ".tmp/linux-migration/zig-local-cache"))
        self.assertIn("-Dcpu=baseline", arguments)
        self.assertIn("-Doptimize=Debug", arguments)
        backend = self.directory / "build/linux-dev/bin/DevSpaceLinuxBackend"
        self.assertEqual(backend.read_text(), "controlled backend artifact")

    def test_compiler_failure_does_not_publish_backend_as_a_complete_build(self):
        self.zig.write_text("#!/usr/bin/env python3\nraise SystemExit(42)\n")
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.directory / "build/linux-dev/bin/DevSpaceLinuxBackend").exists())

    def test_run_builds_and_refreshes_a_development_bundle(self):
        # The compiler peer supplies artifacts; Make, assembly, and launcher are real.
        self.zig.write_text("#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\n"
                            "prefix=Path(sys.argv[sys.argv.index('--prefix')+1])\n"
                            "(prefix/'bin').mkdir(parents=True,exist_ok=True)\n"
                            "p=prefix/'bin/ghostty'\n"
                            "p.write_text(\"#!/usr/bin/env python3\\nimport json,os\\n"
                            "print(json.dumps({'channel':os.environ['DEVSPACE_BUILD_CHANNEL'],"
                            "'backend':os.environ['DEVSPACE_BACKEND']}))\\n\")\n"
                            "p.chmod(0o755)\n"
                            "(prefix/'lib').mkdir(exist_ok=True)\n"
                            "(prefix/'share/ghostty').mkdir(parents=True,exist_ok=True)\n")
        for _ in range(2):
            result = subprocess.run(["make", "linux-run", f"LINUX_FRONTEND={self.frontend}",
                                     f"SWIFT={self.swift}", f"ZIG={self.zig}",
                                     f"LINUX_SWIFT_RUNTIME={self.runtime}"], cwd=self.directory,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            launched = json.loads(result.stdout.splitlines()[-1])
            self.assertEqual(launched["channel"], "development")
            self.assertEqual(launched["backend"],
                             str(self.directory / "build/linux-dev-bundle/bin/DevSpaceDevBackend"))
            self.assertEqual(Path(launched["backend"]).read_text(), "controlled backend artifact")

    def test_protocol_target_keeps_both_compiler_caches_inside_the_project(self):
        self.zig.write_text("#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\n"
                            "Path('arguments.json').write_text(json.dumps(sys.argv[1:]))\n")
        result = subprocess.run(["make", "linux-test-protocol", f"ZIG={self.zig}"],
                                cwd=self.directory, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads((self.directory / "arguments.json").read_text())
        self.assertIn("--global-cache-dir", arguments, "the sandbox cannot write the default home cache")
        self.assertEqual(arguments[arguments.index("--global-cache-dir") + 1],
                         ".tmp/linux-migration/zig-cache")
        self.assertEqual(arguments[arguments.index("--cache-dir") + 1],
                         ".tmp/linux-migration/zig-local-cache")

    def test_gtk_target_runs_the_native_integration_test_with_shared_caches(self):
        self.zig.write_text("#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\n"
                            "Path('../arguments.json').write_text(json.dumps(sys.argv[1:]))\n")
        result = subprocess.run(["make", "linux-test-gtk", f"ZIG={self.zig}",
                                 f"LINUX_FRONTEND={self.frontend}"], cwd=self.directory,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads((self.directory / "arguments.json").read_text())
        self.assertEqual(arguments[:2], ["build", "test-devspace"])
        self.assertIn("-Dcpu=baseline", arguments)
        self.assertEqual(arguments[arguments.index("--cache-dir") + 1],
                         str(self.directory / ".tmp/linux-migration/zig-local-cache"))
