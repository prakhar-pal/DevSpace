"""Exercise the real Linux launcher and bundle assembly in isolated paths."""

import json
import os
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/assemble-linux.py"


class AssembleLinuxTests(unittest.TestCase):
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
        self.runtime = self.directory / "runtime"
        self.runtime.mkdir()
        (self.runtime / "libswiftCore.so").write_text("Swift runtime")
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
