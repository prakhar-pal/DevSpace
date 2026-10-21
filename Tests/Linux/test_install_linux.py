"""Install real assembled bundles only into isolated test prefixes."""

import json
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
INSTALL = ROOT / "scripts/install-linux.py"


class InstallLinuxTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / ".tmp")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.prefix = self.directory / "local prefix α"
        self.bundle = self.directory / "production"
        frontend = self.directory / "frontend/bin"
        frontend.mkdir(parents=True)
        (frontend / "DevSpaceLinuxApp").write_text('#!/bin/sh\nprintf "installed:%s\\n" "$1"\n')
        (frontend / "DevSpaceLinuxApp").chmod(0o755)
        backend = self.directory / "backend"
        backend.write_text("#!/bin/sh\nexit 0\n")
        runtime = self.directory / "toolchain/usr/lib/swift/linux"
        self.runtime = runtime
        runtime.mkdir(parents=True)
        (runtime / "libswiftCore.so").write_text("runtime fixture")
        notice = self.directory / "toolchain/usr/share/swift/LICENSE.txt"
        notice.parent.mkdir(parents=True)
        notice.write_text("runtime notice fixture")
        subprocess.run([sys.executable, str(ROOT / "scripts/assemble-linux.py"),
            "--frontend", str(frontend.parent), "--backend", str(backend),
            "--swift-runtime", str(runtime), "--channel", "production",
            "--output", str(self.bundle)], check=True, capture_output=True)

    def install(self):
        return subprocess.run([sys.executable, str(INSTALL), "--bundle", str(self.bundle),
            "--prefix", str(self.prefix)], capture_output=True, text=True)

    def test_installs_relocatable_launcher_desktop_icon_and_notices(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = self.prefix / "lib/devspace"
        self.assertEqual(json.loads((installed / ".devspace-bundle.json").read_text())["channel"], "production")
        launch = subprocess.run([str(self.prefix / "bin/devspace"), "two words α"],
            env=dict(os.environ, PATH="/usr/bin:/bin"), capture_output=True, text=True)
        self.assertEqual(launch.returncode, 0, launch.stderr)
        self.assertEqual(launch.stdout, "installed:two words α\n")
        desktop = self.prefix / "share/applications/com.prakharp.devspace.desktop"
        self.assertIn(f'Exec=/usr/bin/env "{installed}/bin/devspace"\n', desktop.read_text())
        icon = self.prefix / "share/icons/hicolor/512x512/apps/com.prakharp.devspace.png"
        self.assertTrue(icon.read_bytes().startswith(b"\x89PNG"))
        self.assertTrue((installed / "share/doc/devspace/LICENSE").is_file())
        self.assertEqual((self.bundle / "share/applications/com.prakharp.devspace.desktop").read_text().split("Exec=")[1].splitlines()[0], "devspace")

    def test_repeated_install_updates_only_owned_bundle(self):
        self.assertEqual(self.install().returncode, 0)
        (self.bundle / "bin/DevSpaceBackend").write_text("updated backend")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.prefix / "lib/devspace/bin/DevSpaceBackend").read_text(), "updated backend")

    def test_refuses_unknown_destination_or_conflicting_launcher(self):
        for relative in ["lib/devspace", "bin/devspace", "share/applications/com.prakharp.devspace.desktop"]:
            with self.subTest(relative=relative):
                target = self.prefix / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("unrelated data")
                result = self.install()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Refusing", result.stderr)
                self.assertEqual(target.read_text(), "unrelated data")
                target.unlink()

    def test_refuses_development_bundle(self):
        (self.bundle / ".devspace-bundle.json").write_text(json.dumps({
            "producer": "devspace-linux-bundle", "version": 1, "channel": "development"}))
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("production bundle", result.stderr)
        self.assertFalse((self.prefix / "lib/devspace").exists())

    def test_refuses_running_frontend_or_backend_without_killing_it(self):
        self.assertEqual(self.install().returncode, 0)
        blocking = self.directory / "blocking-child"
        subprocess.run(["cc", "-x", "c", "-", "-o", str(blocking)],
            input="#include <unistd.h>\nint main(void) { for (;;) pause(); }\n",
            text=True, check=True, capture_output=True)
        for name in ["DevSpace", "DevSpaceBackend"]:
            with self.subTest(name=name):
                binary = self.prefix / "lib/devspace/bin" / name
                shutil.copy2(blocking, binary)
                child = subprocess.Popen([str(binary)])
                try:
                    result = self.install()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("running", result.stderr)
                    self.assertIsNone(child.poll())
                finally:
                    child.terminate()
                    child.wait(timeout=5)

    def test_make_install_uses_linux_installer_without_macos_build(self):
        result = subprocess.run(["make", "install", f"LINUX_INSTALL_BUNDLE={self.bundle}",
            f"LINUX_INSTALL_PREFIX={self.prefix}"], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("DevSpaceApp", result.stdout)
        self.assertNotIn("ditto", result.stdout)
        self.assertTrue((self.prefix / "bin/devspace").is_file())

    def test_make_install_without_bundle_builds_release_and_preserves_lock(self):
        compiler = self.directory / "swift-fixture"
        calls = self.directory / "swift-calls.jsonl"
        compiler.write_text("#!/usr/bin/python3\nimport json,pathlib,shutil,sys\n"
            f"calls=pathlib.Path({str(calls)!r})\n"
            "with calls.open('a') as log: log.write(json.dumps(sys.argv[1:])+'\\n')\n"
            "args=sys.argv[1:]\n"
            "assert args[:3] == ['build','-c','release']\n"
            "product=args[args.index('--product')+1]\n"
            "out=pathlib.Path(args[args.index('--scratch-path')+1])/'release'/product\n"
            "out.parent.mkdir(parents=True,exist_ok=True)\n"
            f"source=pathlib.Path({str(self.bundle / 'bin')!r})\n"
            "shutil.copy2(source/({'DevSpaceLinuxApp':'DevSpace','DevSpaceLinuxBackend':'DevSpaceBackend'}[product]),out)\n")
        compiler.chmod(0o755)
        lock_path = ROOT / "Package.resolved"
        lock = lock_path.read_bytes() if lock_path.exists() else None
        result = subprocess.run(["make", "install", f"SWIFT={compiler}",
            f"LINUX_RELEASE_SCRATCH={self.directory / 'release-cache'}",
            f"LINUX_SWIFT_RUNTIME={self.runtime}", f"LINUX_INSTALL_PREFIX={self.prefix}"],
            cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([json.loads(line)[4] for line in calls.read_text().splitlines()],
                         ["DevSpaceLinuxApp", "DevSpaceLinuxBackend"])
        self.assertTrue((self.prefix / "bin/devspace").is_file())
        self.assertEqual(lock_path.read_bytes() if lock_path.exists() else None, lock)

    @unittest.skipUnless(shutil.which("desktop-file-validate") and shutil.which("gio"), "desktop entry tools required")
    def test_desktop_launch_handles_reserved_characters_in_prefix(self):
        self.prefix = self.directory / 'quoted "prefix" \\ % $ ` α'
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        desktop = self.prefix / "share/applications/com.prakharp.devspace.desktop"
        checked = subprocess.run(["desktop-file-validate", str(desktop)], capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        launched = subprocess.run(["gio", "launch", str(desktop)], capture_output=True, text=True, timeout=10)
        self.assertEqual(launched.returncode, 0, launched.stderr)
        self.assertIn("installed:", launched.stdout)

    def test_macos_install_dry_run_preserves_existing_recipe(self):
        tools = self.directory / "mac-tools"
        tools.mkdir()
        uname = tools / "uname"
        uname.write_text("#!/bin/sh\nprintf 'Darwin\\n'\n")
        uname.chmod(0o755)
        result = subprocess.run(["make", "-n", "install"], cwd=ROOT,
            env=dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}"), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--product DevSpaceApp", result.stdout)
        self.assertIn("ditto", result.stdout)
        self.assertNotIn("install-linux.py", result.stdout)

    def test_refuses_symlinked_install_parent_outside_prefix(self):
        outside = self.directory / "unrelated"
        outside.mkdir()
        self.prefix.mkdir()
        (self.prefix / "lib").symlink_to(outside, target_is_directory=True)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing", result.stderr)
        self.assertEqual(list(outside.iterdir()), [])

    def test_failed_registration_preserves_existing_bundle(self):
        self.assertEqual(self.install().returncode, 0)
        installed = self.prefix / "lib/devspace/bin/DevSpaceBackend"
        old = installed.read_bytes()
        (self.bundle / "bin/DevSpaceBackend").write_text("replacement")
        desktop = self.prefix / "share/applications/com.prakharp.devspace.desktop"
        desktop.unlink()
        spec = importlib.util.spec_from_file_location("install_linux", INSTALL)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with patch.object(Path, "symlink_to", side_effect=OSError("controlled registration failure")):
            with self.assertRaises(OSError):
                module.install(self.bundle, self.prefix)
        self.assertEqual(installed.read_bytes(), old)
        self.assertFalse(desktop.exists())

    def test_failed_rollback_keeps_previous_bundle_recoverable(self):
        self.assertEqual(self.install().returncode, 0)
        installed = self.prefix / "lib/devspace/bin/DevSpaceBackend"
        old = installed.read_bytes()
        (self.bundle / "bin/DevSpaceBackend").write_text("replacement")
        (self.prefix / "share/applications/com.prakharp.devspace.desktop").unlink()
        spec = importlib.util.spec_from_file_location("install_linux", INSTALL)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        rename = Path.rename
        def fail_restore(path, target):
            if path.name == "previous":
                raise OSError("controlled rollback failure")
            return rename(path, target)
        with patch.object(Path, "symlink_to", side_effect=OSError("controlled registration failure")), \
             patch.object(Path, "rename", fail_restore):
            with self.assertRaises((OSError, RuntimeError)):
                module.install(self.bundle, self.prefix)
        backups = list((self.prefix / "lib").glob(".devspace-previous-*/previous/bin/DevSpaceBackend"))
        self.assertEqual(len(backups), 1, "failed rollback must not delete the old bundle")
        self.assertEqual(backups[0].read_bytes(), old)


if __name__ == "__main__":
    unittest.main()
