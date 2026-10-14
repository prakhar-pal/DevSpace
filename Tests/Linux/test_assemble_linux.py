"""Exercise the real Linux launcher and bundle assembly in isolated paths."""

import json
import os
import plistlib
import ctypes.util
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/assemble-linux.py"
PACKAGE_SCRIPT = ROOT / "scripts/package-linux.py"


class AssembleLinuxTests(unittest.TestCase):
    def test_bundle_preserves_project_and_selected_toolchain_license(self):
        swift_license = self.directory / "swift-LICENSE.txt"
        swift_license.write_text("Selected toolchain license fixture\n")
        result = subprocess.run([
            sys.executable, str(SCRIPT), "--frontend", str(self.frontend),
            "--backend", str(self.backend), "--swift-runtime", str(self.runtime),
            "--swift-license", str(swift_license), "--channel", "production",
            "--output", str(self.output),
        ], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        documentation = self.output / "share/doc/devspace"
        self.assertEqual((documentation / "LICENSE").read_bytes(), (ROOT / "LICENSE").read_bytes())
        self.assertEqual((documentation / "swift-runtime-LICENSE.txt").read_bytes(), swift_license.read_bytes())
        self.assertIn("GPL-3.0-or-later", (documentation / "licensing.txt").read_text())

    def test_launcher_finds_user_local_tools_with_minimal_gui_path(self):
        home = self.directory / "home"
        tools = home / ".local/bin"
        tools.mkdir(parents=True)
        for name in ("devpod", "zed"):
            tool = tools / name
            tool.write_text("#!/bin/sh\nprintf FOUND\n")
            tool.chmod(0o755)
        (self.frontend / "bin/DevSpaceLinuxApp").write_text("#!/bin/sh\ncommand -v devpod && command -v zed\n")
        self.assertEqual(self.assemble().returncode, 0)
        env = dict(os.environ, HOME=str(home), PATH="/usr/bin:/bin")
        result = subprocess.run([str(self.output / "bin/devspace-dev")], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [str(tools / "devpod"), str(tools / "zed")])

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / ".tmp")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.frontend = self.directory / "frontend"
        (self.frontend / "bin").mkdir(parents=True)
        executable = self.frontend / "bin/DevSpaceLinuxApp"
        executable.write_text("#!/usr/bin/env python3\nimport json,os,sys\n"
                              "print(json.dumps({'args':sys.argv[1:],'channel':os.environ['DEVSPACE_BUILD_CHANNEL'],"
                              "'backend':os.environ['DEVSPACE_BACKEND'],"
                              "'libraries':os.environ['LD_LIBRARY_PATH']}))\n")
        executable.chmod(0o755)
        self.backend = self.directory / "backend"
        self.backend.write_text("backend artifact")
        self.runtime = self.directory / "toolchain/usr/lib/swift/linux"
        self.runtime.mkdir(parents=True)
        (self.runtime / "libswiftCore.so").write_text("Swift runtime")
        notice = self.directory / "toolchain/usr/share/swift/LICENSE.txt"
        notice.parent.mkdir(parents=True)
        notice.write_text("Swift toolchain license fixture\n")
        self.output = self.directory / "installed bundle α"

    def assemble(self, channel="development", replace=False):
        return subprocess.run([sys.executable, str(SCRIPT), "--frontend", str(self.frontend),
                               "--backend", str(self.backend), "--swift-runtime", str(self.runtime),
                               "--channel", channel, "--output", str(self.output)] +
                              (["--replace"] if replace else []),
                              capture_output=True, text=True)

    def test_launcher_uses_relocated_bundle_and_preserves_arguments(self):
        result = self.assemble()
        self.assertEqual(result.returncode, 0, result.stderr)
        moved = self.directory / "moved bundle β"
        self.output.rename(moved)
        result = subprocess.run([str(moved / "bin/devspace-dev"), "argument with spaces", "α"],
                                cwd=self.directory, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        launched = json.loads(result.stdout)
        self.assertEqual(launched["channel"], "development")
        self.assertEqual(launched["backend"], str(moved / "bin/DevSpaceDevBackend"))
        self.assertEqual(launched["libraries"].split(":")[0], str(moved / "lib"))
        self.assertEqual(launched["args"], ["argument with spaces", "α"])
        self.assertEqual((moved / "lib/libswiftCore.so").read_text(), "Swift runtime")
        self.assertFalse((moved / "share/ghostty").exists())
        self.assertTrue((moved / "bin/DevSpaceDev").is_file())

    def test_production_has_distinct_executables_and_desktop_identity(self):
        result = self.assemble("production")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run([str(self.output / "bin/devspace"), "+version"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        launched = json.loads(result.stdout)
        self.assertEqual(launched["channel"], "production")
        self.assertEqual(launched["backend"], str(self.output / "bin/DevSpaceBackend"))
        self.assertTrue((self.output / "bin/DevSpace").is_file())
        self.assertFalse((self.output / "bin/DevSpaceDev").exists())
        self.assertTrue((self.output / "share/applications/com.prakharp.devspace.desktop").is_file())
        icons = list((self.output / "share/icons/hicolor").glob("*/apps/com.prakharp.devspace.png"))
        self.assertEqual(len(icons), 1)
        self.assertTrue(icons[0].read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))

    def test_deb_installs_production_bundle_with_system_dependencies_and_notices(self):
        xml_library = ctypes.util.find_library("xml2")
        self.assertIsNotNone(xml_library, "system XML library is required by Swift FoundationXML")
        probe = subprocess.run([
            "cc", "-shared", "-fPIC", "-x", "c", "-", f"-l:{xml_library}",
            "-o", str(self.runtime / "libxml-dependency-probe.so"),
        ], input="extern void xmlCheckVersion(int); void probe(void) { xmlCheckVersion(0); }\n",
            capture_output=True, text=True)
        self.assertEqual(probe.returncode, 0, probe.stderr)
        self.assertEqual(self.assemble("production").returncode, 0)
        copyright_file = self.directory / "debian-copyright"
        copyright_text = (
            "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/\n"
            "Upstream-Name: DevSpace\nSource: https://example.invalid/\n\n"
            "Files: *\nCopyright: test fixture only\nLicense: test-fixture\n"
            " This text is only a package-builder test fixture.\n"
        )
        copyright_file.write_text(copyright_text)
        swift_license = self.directory / "swift-LICENSE.txt"
        swift_license.write_text("Swift runtime license test fixture\n")
        package = self.directory / "devspace.deb"
        maintainer = "DevSpace test fixture <devspace@example.invalid>"
        package_command = [
            sys.executable, str(PACKAGE_SCRIPT), "--bundle", str(self.output),
            "--copyright-file", str(copyright_file), "--swift-license", str(swift_license),
            "--maintainer", maintainer, "--output", str(package),
        ]
        result = subprocess.run(package_command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        original_package = package.read_bytes()
        repeat = subprocess.run(package_command, capture_output=True, text=True)
        self.assertNotEqual(repeat.returncode, 0)
        self.assertIn("output already exists", repeat.stderr)
        self.assertEqual(package.read_bytes(), original_package)
        self.assertEqual(subprocess.check_output(["dpkg-deb", "-f", str(package), "Package"], text=True).strip(),
                         "devspace")
        self.assertEqual(subprocess.check_output(["dpkg-deb", "-f", str(package), "Version"], text=True).strip(),
                         plistlib.loads((ROOT / "Info.plist").read_bytes())["CFBundleShortVersionString"])
        self.assertEqual(subprocess.check_output(["dpkg-deb", "-f", str(package), "Architecture"], text=True).strip(),
                         subprocess.check_output(["dpkg", "--print-architecture"], text=True).strip())
        self.assertEqual(subprocess.check_output(["dpkg-deb", "-f", str(package), "Maintainer"], text=True).strip(),
                         maintainer)
        dependencies = subprocess.check_output(["dpkg-deb", "-f", str(package), "Depends"], text=True)
        for dependency in ("libgtk-4-1", "libvte-2.91-gtk4-0", "openssh-client", "util-linux"):
            self.assertIn(dependency, dependencies)
        self.assertRegex(dependencies, r"libxml2[^,]* \(>= [^)]+\)")

        extracted = self.directory / "extracted"
        subprocess.run(["dpkg-deb", "-x", str(package), str(extracted)], check=True)
        prefix = extracted / "usr/lib/devspace"
        self.assertTrue((prefix / "bin/DevSpace").is_file())
        self.assertTrue((prefix / "bin/DevSpaceBackend").is_file())
        self.assertTrue((prefix / "lib/libswiftCore.so").is_file())
        launcher = extracted / "usr/bin/devspace"
        self.assertTrue(launcher.is_symlink())
        self.assertEqual(os.readlink(launcher), "../lib/devspace/bin/devspace")
        desktop = extracted / "usr/share/applications/devspace.desktop"
        self.assertIn("Exec=/usr/bin/devspace\n", desktop.read_text())
        self.assertTrue(list((extracted / "usr/share/icons/hicolor").glob(
            "*/apps/com.prakharp.devspace.png")))
        self.assertEqual((extracted / "usr/share/doc/devspace/copyright").read_text(), copyright_text)
        self.assertEqual((extracted / "usr/share/doc/devspace/swift-runtime-LICENSE.txt").read_text(),
                         "Swift runtime license test fixture\n")

        environment = dict(os.environ, PATH="/usr/bin:/bin", HOME=str(self.directory / "home"))
        run = subprocess.run([str(launcher), "arg with spaces"], env=environment,
                             capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        launched = json.loads(run.stdout)
        self.assertEqual(launched["channel"], "production")
        self.assertEqual(launched["backend"], str(prefix / "bin/DevSpaceBackend"))
        self.assertEqual(launched["args"], ["arg with spaces"])

    def test_deb_requires_project_copyright_and_does_not_overwrite_output(self):
        self.assertEqual(self.assemble("production").returncode, 0)
        output = self.directory / "existing.deb"
        output.write_text("keep this unrelated file")
        result = subprocess.run([
            sys.executable, str(PACKAGE_SCRIPT), "--bundle", str(self.output),
            "--swift-license", str(self.directory / "missing-license"),
            "--maintainer", "DevSpace test fixture <devspace@example.invalid>",
            "--output", str(output),
        ], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output.read_text(), "keep this unrelated file")

    def test_deb_rejects_a_non_debian_copyright_file(self):
        self.assertEqual(self.assemble("production").returncode, 0)
        copyright_file = self.directory / "not-debian-copyright"
        copyright_file.write_text("This is not a copyright manifest.\n")
        swift_license = self.directory / "swift-LICENSE.txt"
        swift_license.write_text("Swift license test fixture\n")
        output = self.directory / "devspace.deb"
        result = subprocess.run([
            sys.executable, str(PACKAGE_SCRIPT), "--bundle", str(self.output),
            "--copyright-file", str(copyright_file), "--swift-license", str(swift_license),
            "--maintainer", "DevSpace test fixture <devspace@example.invalid>",
            "--output", str(output),
        ], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Debian copyright-format 1.0 manifest", result.stderr)
        self.assertFalse(output.exists())

    def test_existing_output_is_not_overwritten(self):
        self.output.mkdir()
        (self.output / "local").write_text("keep")
        result = self.assemble()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr)
        self.assertEqual((self.output / "local").read_text(), "keep")

    def test_replace_refreshes_only_a_matching_generated_bundle(self):
        result = self.assemble()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.backend.write_text("updated backend")
        result = self.assemble(replace=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output / "bin/DevSpaceDevBackend").read_text(), "updated backend")
        result = self.assemble("production", replace=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.output / "bin/DevSpaceDevBackend").read_text(), "updated backend")

    def test_replace_does_not_remove_an_unmarked_directory(self):
        self.output.mkdir()
        (self.output / "local").write_text("keep")
        result = self.assemble(replace=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.output / "local").read_text(), "keep")

    def test_failed_replacement_preserves_the_previous_bundle(self):
        self.assertEqual(self.assemble().returncode, 0)
        self.backend.unlink()
        result = self.assemble(replace=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.output / "bin/DevSpaceDevBackend").read_text(), "backend artifact")
        self.assertEqual(list(self.directory.glob(".devspace-bundle-*")), [])

    def test_replace_rejects_a_symlink_to_a_generated_bundle(self):
        self.assertEqual(self.assemble().returncode, 0)
        original = self.directory / "original"
        self.output.rename(original)
        self.output.symlink_to(original, target_is_directory=True)
        result = self.assemble(replace=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.output.is_symlink())
        self.assertEqual((original / "bin/DevSpaceDevBackend").read_text(), "backend artifact")

    def test_interrupted_publication_restores_the_previous_bundle(self):
        self.assertEqual(self.assemble().returncode, 0)
        self.backend.write_text("updated backend")
        specification = importlib.util.spec_from_file_location("assemble_linux", SCRIPT)
        assembler = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(assembler)
        rename = Path.rename

        def interrupt_publication(source, destination):
            if source.name == "bundle" and destination == self.output:
                raise KeyboardInterrupt()
            return rename(source, destination)

        arguments = [str(SCRIPT), "--frontend", str(self.frontend), "--backend", str(self.backend),
                     "--swift-runtime", str(self.runtime), "--channel", "development",
                     "--output", str(self.output), "--replace"]
        with patch.object(sys, "argv", arguments), patch.object(Path, "rename", interrupt_publication):
            with self.assertRaises(KeyboardInterrupt):
                assembler.main()
        self.assertTrue(self.output.is_dir(), "interruption must not discard the old bundle")
        self.assertEqual((self.output / "bin/DevSpaceDevBackend").read_text(), "backend artifact")

    def test_failed_rollback_keeps_a_recoverable_previous_bundle(self):
        self.assertEqual(self.assemble().returncode, 0)
        specification = importlib.util.spec_from_file_location("assemble_linux", SCRIPT)
        assembler = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(assembler)
        rename = Path.rename

        def fail_publication_and_rollback(source, destination):
            if destination == self.output:
                raise OSError("controlled publication/rollback failure")
            return rename(source, destination)

        arguments = [str(SCRIPT), "--frontend", str(self.frontend), "--backend", str(self.backend),
                     "--swift-runtime", str(self.runtime), "--channel", "development",
                     "--output", str(self.output), "--replace"]
        with patch.object(sys, "argv", arguments), patch.object(Path, "rename", fail_publication_and_rollback):
            with self.assertRaises((OSError, RuntimeError)):
                assembler.main()
        recovered = list(self.directory.glob(".devspace-previous-*/previous/bin/DevSpaceDevBackend"))
        self.assertEqual(len(recovered), 1, "failed rollback must leave the old bundle recoverable")
        self.assertEqual(recovered[0].read_text(), "backend artifact")
