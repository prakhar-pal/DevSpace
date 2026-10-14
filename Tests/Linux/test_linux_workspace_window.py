"""Exercise the Swift GTK/VTE workspace adapter and app controller on Xvfb."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LinuxWorkspaceWindowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler = os.environ.get("DEVSPACE_SWIFTC") or shutil.which("swiftc")
        if not cls.compiler:
            raise unittest.SkipTest("Swift compiler must be installed")
        cls.temporary = tempfile.TemporaryDirectory(dir=ROOT / ".tmp")
        cls.build = Path(cls.temporary.name)
        cls.pkg_cflags = shlex.split(subprocess.check_output(
            ["pkg-config", "--cflags", "gtk4", "vte-2.91-gtk4"], text=True
        ))
        cls.pkg_libs = shlex.split(subprocess.check_output(
            ["pkg-config", "--libs", "gtk4", "vte-2.91-gtk4"], text=True
        ))

        cpty = subprocess.run([
            "cc", "-shared", "-fPIC", "-I", str(ROOT / "Sources/CPTY/include"),
            str(ROOT / "Sources/CPTY/cpty.c"), "-lutil", "-o", str(cls.build / "libCPTY.so"),
        ], cwd=ROOT, capture_output=True, text=True)
        if cpty.returncode:
            raise AssertionError(cpty.stderr)

        core = subprocess.run([
            cls.compiler, "-emit-library", "-emit-module", "-module-name", "DevSpaceCore",
            "-emit-module-path", str(cls.build / "DevSpaceCore.swiftmodule"),
            "-module-cache-path", str(cls.build / "core-module-cache"),
            "-Xcc", f"-fmodule-map-file={ROOT / 'Tests/Linux/fixtures/CPTY.modulemap'}",
            *map(str, sorted((ROOT / "Sources/Core").glob("*.swift"))),
            "-L", str(cls.build), "-lCPTY", "-lutil", "-Xlinker", "-rpath", "-Xlinker", str(cls.build),
            "-o", str(cls.build / "libDevSpaceCore.so"),
        ], cwd=ROOT, capture_output=True, text=True)
        if core.returncode:
            raise AssertionError(core.stderr)

        cls.workspace_runner = cls.build_runner(
            "Tests/LinuxApp/WorkspaceWindowTests.swift", "workspace-window-tests", include_backend=False
        )
        cls.app_runner = cls.build_runner(
            "Tests/LinuxApp/LinuxApplicationTests.swift", "linux-application-tests", include_backend=True
        )
        cls.backend_runner = subprocess.run([
            cls.compiler, "-I", str(cls.build), "-L", str(cls.build), "-lDevSpaceCore", "-lCPTY", "-lutil",
            "-Xlinker", "-rpath", "-Xlinker", str(cls.build),
            "-Xcc", f"-fmodule-map-file={ROOT / 'Tests/Linux/fixtures/CPTY.modulemap'}",
            "-I", str(ROOT / "Sources/CPTY/include"),
            "-module-cache-path", str(cls.build / "backend-module-cache"),
            str(ROOT / "Sources/LinuxBackend/main.swift"), "-o", str(cls.build / "DevSpaceLinuxBackend"),
        ], cwd=ROOT, capture_output=True, text=True)
        if cls.backend_runner.returncode:
            raise AssertionError(cls.backend_runner.stderr)
        cls.backend_binary = cls.build / "DevSpaceLinuxBackend"

    @classmethod
    def build_runner(cls, test_source, output_name, include_backend):
        app_sources = sorted(
            path for path in (ROOT / "Sources/LinuxApp").glob("*.swift")
            if path.name != "main.swift" and (
                include_backend or path.name in {"WorkspaceWindow.swift", "TerminalPane.swift"}
            )
        )
        command = [
            cls.compiler, "-I", str(cls.build), "-L", str(cls.build), "-lDevSpaceCore", "-lCPTY", "-lutil",
            "-Xlinker", "-rpath", "-Xlinker", str(cls.build),
            "-Xcc", f"-fmodule-map-file={ROOT / 'Tests/Linux/fixtures/CPTY.modulemap'}",
            "-I", str(ROOT / "Sources/CPTY/include"),
            "-I", str(ROOT / "Sources/LinuxGTK"), "-I", str(ROOT / "Sources/LinuxVTE"),
            "-module-cache-path", str(cls.build / f"{output_name}-module-cache"),
            *map(str, app_sources), str(ROOT / test_source), "-o", str(cls.build / output_name),
        ]
        for flag in cls.pkg_cflags:
            command.extend(["-Xcc", flag])
        command.extend(cls.pkg_libs)
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stderr)
        return cls.build / output_name

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "temporary"):
            cls.temporary.cleanup()

    def test_snapshot_and_terminal_effect_lifecycle(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(
            ["xvfb-run", "-a", str(self.workspace_runner)], cwd=ROOT, env=environment,
            capture_output=True, text=True, timeout=12,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("snapshot-identity=stable stale-generation=rejected close=workspace-preserved", result.stdout)

    def test_backend_snapshot_effects_and_shutdown_reach_the_gtk_window(self):
        events = self.build / "linux-app-events.jsonl"
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none",
                           DEVSPACE_TEST_EVENTS=str(events))
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(
            ["xvfb-run", "-a", str(self.app_runner), shutil.which("python3") or "/usr/bin/python3",
             str(ROOT / "Tests/Linux/fixtures/linux_ui_backend_peer.py"), "normal"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("snapshot=received terminal=opened stale-effects=rejected shutdown=orderly", result.stdout)
        frames = [json.loads(line) for line in events.read_text().splitlines()]
        requests = [frame["kind"] for frame in frames]
        self.assertIn("terminal_output", requests)
        self.assertIn("terminal_exit", requests)
        self.assertIn("shutdown", requests)
        self.assertEqual([frame["payload"]["workspace_id"] for frame in frames if frame["kind"] == "select"],
                         ["fixture-pod"])
        self.assertEqual(requests.count("connect"), 1)
        self.assertFalse(any(kind in {"stop", "delete", "recreate"} for kind in requests))

    def test_backend_crash_disables_actions_without_freezing_gtk(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(
            ["xvfb-run", "-a", str(self.app_runner), shutil.which("python3") or "/usr/bin/python3",
             str(ROOT / "Tests/Linux/fixtures/linux_ui_backend_peer.py"), "crash"],
            cwd=ROOT, env=environment,
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("backend-failure=visible actions=disabled gtk=responsive", result.stdout)

    def test_missing_zed_and_nonzero_exit_are_visible_without_breaking_the_terminal(self):
        for name in ("missing", "exits-nonzero"):
            with self.subTest(editor=name):
                tools = self.build / name
                tools.mkdir()
                if name == "exits-nonzero":
                    executable = tools / "zed"
                    executable.write_text("#!/bin/sh\nexit 37\n")
                    executable.chmod(0o755)
                environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
                environment.pop("WAYLAND_DISPLAY", None)
                result = subprocess.run([
                    "xvfb-run", "-a", "/usr/bin/env", f"PATH={tools}", str(self.app_runner),
                    shutil.which("python3") or "/usr/bin/python3",
                    str(ROOT / "Tests/Linux/fixtures/linux_ui_backend_peer.py"), "zed-failure",
                ], cwd=ROOT, env=environment, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("zed-failure=visible terminal=round-trip actions=enabled", result.stdout)

    @unittest.skipUnless(os.environ.get("DEVSPACE_HOST_UI_WORKSPACE"),
                         "opt-in authorized real workspace through GTK/VTE")
    def test_real_workspace_shell_round_trips_through_the_vte_widget(self):
        workspace = os.environ["DEVSPACE_HOST_UI_WORKSPACE"]
        channel = os.environ.get("DEVSPACE_TEST_CHANNEL", "production")
        display_backend = os.environ.get("DEVSPACE_HOST_UI_DISPLAY", "")
        self.assertIn(display_backend, ("", "wayland", "x11"))
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND=display_backend or "x11", GTK_A11Y="none",
                           DEVSPACE_TEST_CHANNEL=channel)
        if display_backend != "wayland":
            environment.pop("WAYLAND_DISPLAY", None)
        command = [str(self.app_runner), str(self.backend_binary), workspace, "host"]
        if not display_backend:
            command = ["xvfb-run", "-a", *command]
        with tempfile.TemporaryDirectory(dir=self.build) as temporary:
            if os.environ.get("DEVSPACE_HOST_UI_INTEGRATION") == "1":
                self.assertEqual(channel, "development", "helper installation is development-only")
                tools = Path(temporary)
                record = tools / "zed-argument"
                executable = tools / "zed"
                executable.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$DEVSPACE_HOST_UI_ZED_RECORD"\n')
                executable.chmod(0o755)
                environment["PATH"] = f"{tools}:{environment.get('PATH', '/usr/bin:/bin')}"
                environment["DEVSPACE_HOST_UI_ZED_RECORD"] = str(record)
            result = subprocess.run(
                command,
                cwd=ROOT, env=environment, capture_output=True, text=True, timeout=120,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("host-vte workspace=connected shell=round-trip close=workspace-preserved",
                      result.stdout)
        self.assertIn("reopen=new-pane-round-trip", result.stdout)
        if os.environ.get("DEVSPACE_HOST_UI_IMAGE") == "1":
            self.assertIn("image=uploaded-verified-cleaned", result.stdout)
        if os.environ.get("DEVSPACE_HOST_UI_INTEGRATION") == "1":
            self.assertIn("integration=helper-badge-ded-routed", result.stdout)

    def test_existing_python_backend_regression_suite(self):
        environment = dict(os.environ, DEVSPACE_TEST_BACKEND=str(self.backend_binary))
        result = subprocess.run(
            [sys.executable, "-B", "-m", "unittest", "Tests.Linux.test_backend", "-v"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=180,
        )
        self.assertEqual(result.returncode, 0, result.stdout[-5000:] + result.stderr[-5000:])
        self.assertIn("OK", result.stderr)


if __name__ == "__main__":
    unittest.main()
