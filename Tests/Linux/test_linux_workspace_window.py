"""Exercise the Swift GTK/VTE workspace adapter and app controller on Xvfb."""

import json
import os
from pathlib import Path
import shlex
import shutil
import signal
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
            *map(str, app_sources), str(ROOT / "Tests/LinuxApp/NativeKeyInput.swift"),
            str(ROOT / test_source), "-o", str(cls.build / output_name),
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

    def test_rendered_spacing_and_content_sized_actions(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        with tempfile.TemporaryFile(mode="w+") as output:
            result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "spacing"],
                cwd=ROOT, env=environment, stdout=output, stderr=subprocess.STDOUT, text=True, timeout=15)
            output.seek(0)
            log = output.read()
        self.assertEqual(result.returncode, 0, log)
        self.assertIn("spacing=separated actions=content-sized dialogs=padded", log)

    def test_button_roles_distinguish_actions_from_selection(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        # Desktop portal children can retain captured pipe descriptors after
        # the runner exits. Wait for the runner, not unrelated pipe EOF.
        with tempfile.TemporaryFile(mode="w+") as output:
            result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "button-roles"],
                cwd=ROOT, env=environment, stdout=output, stderr=subprocess.STDOUT, text=True, timeout=15)
            output.seek(0)
            log = output.read()
        self.assertEqual(result.returncode, 0, log)
        self.assertIn("roles=primary-secondary-destructive selection=distinct validation=preserved", log)

    def test_child_osc52_clipboard_roundtrip_and_hidden_pane_isolation(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "osc52"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("osc52=child-to-clipboard-to-child hidden=ignored closed=ignored", result.stdout)

    def test_terminal_launch_errors_arrive_after_pane_registration(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "launch-errors"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("launch-errors=deferred executable-and-cwd=reported", result.stdout)

    def test_short_lived_children_render_before_exit_callbacks(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "fast-exit"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("fast-exit=visible-output-first cycles=32", result.stdout)

    @unittest.skipUnless(os.environ.get("DEVSPACE_HOST_UI_WORKSPACE"), "opt-in authorized workspace clipboard on private Xvfb")
    def test_real_workspace_clipboard_roundtrip_on_private_display(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "osc52-live"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=110)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("live-devpod=remote-osc52 native-copy=remote-text paste=remote-received", result.stdout)
        self.assertIn("cross-pane=native-copy-to-distinct-child-received", result.stdout)

    @unittest.skipUnless(os.environ.get("DEVSPACE_TEST_DESKTOP_CLIPBOARD") == "1" and
                         os.environ.get("DEVSPACE_HOST_UI_WORKSPACE"), "opt-in physical clipboard replacement")
    def test_real_desktop_clipboard_exchange_with_workspace(self):
        backend = "wayland" if os.environ.get("XDG_SESSION_TYPE") == "wayland" else "x11"
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND=backend, GTK_A11Y="none")
        # Portal descendants can inherit pipes even after the runner exits.
        with tempfile.TemporaryFile(mode="w+", dir=self.build) as output:
            result = subprocess.run([str(self.workspace_runner), "osc52-live"],
                cwd=ROOT, env=environment, stdout=output, stderr=subprocess.STDOUT, text=True, timeout=150)
            output.seek(0)
            log = output.read()
        self.assertEqual(result.returncode, 0, log)
        self.assertIn("desktop-clipboard=external-process-roundtrip remote-paste=received", log)

    def test_start_stop_controls_follow_state_and_operation_lifecycle(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "lifecycle"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("start-stop=state-aware operation=visible cancellation=targeted", result.stdout)

    def test_long_sidebar_scrolls_without_lifecycle_changes(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "scrolling"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("sidebar=scrollable last-workspace=selectable lifecycle=unchanged", result.stdout)

    def test_real_key_delivery_with_terminal_focus_and_modal_ownership(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none",
                           DEVSPACE_PRIVATE_KEY_TEST="1")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "native-keys"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=25)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("native-keys=delivered terminal=preserved modal=owned", result.stdout)

    def test_native_window_commands_use_orderly_backend_shutdown(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none",
                           DEVSPACE_PRIVATE_KEY_TEST="1")
        environment.pop("WAYLAND_DISPLAY", None)
        for mode in ("native-window-quit", "native-window-modal-quit", "native-window-close"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(dir=self.build) as temporary:
                events = Path(temporary) / "events"
                environment["DEVSPACE_TEST_EVENTS"] = str(events)
                # Portal children can inherit pipe FDs after the app exits;
                # wait for the actual runner, not unrelated captured-pipe EOF.
                with (Path(temporary) / "output").open("w+") as output:
                    result = subprocess.run(["xvfb-run", "-a", "dbus-run-session", "--", str(self.app_runner),
                        shutil.which("python3") or "/usr/bin/python3", str(ROOT / "Tests/Linux/fixtures/linux_ui_backend_peer.py"), mode],
                        cwd=ROOT, env=environment, stdout=output, stderr=subprocess.STDOUT, text=True, timeout=15)
                    output.seek(0)
                    log = output.read()
                self.assertEqual(result.returncode, 0, log)
                self.assertIn("native-window-command=delivered shutdown=orderly", log)
                requests = [json.loads(row)["kind"] for row in events.read_text().splitlines()]
                self.assertEqual(requests.count("shutdown"), 1)
                self.assertFalse(set(requests) & {"start", "stop", "recreate", "delete"})

    def test_sidebar_action_buttons_and_targeted_menu(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none",
                           DEVSPACE_PRIVATE_KEY_TEST="1")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "sidebar-controls"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("sidebar-controls=visible framed target=nonselecting disabled=safe", result.stdout)

    def test_friendly_names_ordering_and_modal_shortcut_isolation(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "organization"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("organization=rename-order shortcuts=bounded cancel=nonmutating", result.stdout)

    def test_expanded_hidden_workspaces_scroll_without_oversizing_window(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "hidden-scrolling"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("hidden=scrollable window=bounded footer=reachable", result.stdout)

    def test_first_shell_handoff_guards_input_until_ready(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "handoff"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("handoff=input-guarded managed-input=allowed ready=revealed", result.stdout)

    def test_client_failure_preserves_exit_status_and_retry_slot(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "client-failure"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("client-exit=status-preserved failed-slot=retryable close=explicit", result.stdout)

    def test_provisioning_dialogs_progress_and_guide(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "provisioning"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("provisioning=validated confirmation=required progress=global guide=linux", result.stdout)

    def test_terminal_tabs_preserve_shells_and_creation_order(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "tabs"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("tabs=creation-order active=preserved siblings=independent", result.stdout)

    def test_hidden_workspace_visibility_preserves_selected_terminal(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(["xvfb-run", "-a", str(self.workspace_runner), "visibility"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("visibility=selected-reachable terminal=preserved actions=hide-show", result.stdout)

    @unittest.skipUnless(os.environ.get("DEVSPACE_TEST_HOST_DISPLAY") in ("wayland", "x11"),
                         "opt-in controlled terminal on host display; no physical clipboard access")
    def test_controlled_terminal_and_orderly_quit_on_host_display(self):
        environment = dict(os.environ, GDK_BACKEND=os.environ["DEVSPACE_TEST_HOST_DISPLAY"], GTK_A11Y="none",
                           G_DEBUG="fatal-criticals")
        # A private bus prevents the fixture from activating or quitting the
        # user's real app, even though it uses the development channel ID.
        # Portal descendants can inherit captured pipe FDs after the app and
        # bus launcher exit. Wait for the actual child, not unrelated EOF.
        with tempfile.TemporaryFile(mode="w+t", dir=self.build) as stdout, \
                tempfile.TemporaryFile(mode="w+t", dir=self.build) as stderr:
            process = subprocess.Popen([
                "dbus-run-session", "--", str(self.app_runner), shutil.which("python3") or "/usr/bin/python3",
                str(ROOT / "Tests/Linux/fixtures/linux_ui_backend_peer.py"), "normal",
            ], cwd=ROOT, env=environment, stdout=stdout, stderr=stderr, start_new_session=True)
            timed_out = False
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                timed_out = True
            finally:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
            stdout.seek(0)
            stderr.seek(0)
            output, errors = stdout.read(), stderr.read()
        self.assertFalse(timed_out, "controlled host-display test timed out:\n" + output + errors)
        self.assertEqual(process.returncode, 0, output + errors)
        self.assertIn("snapshot=received terminal=opened stale-effects=rejected shutdown=orderly", output)

    def test_pending_provisioning_and_retained_failure_reach_the_gtk_window(self):
        environment = dict(os.environ, G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
        environment.pop("WAYLAND_DISPLAY", None)
        for mode in ("provisioning", "provisioning-recreate"):
            with self.subTest(mode=mode):
                result = subprocess.run(["xvfb-run", "-a", str(self.app_runner), shutil.which("python3") or "/usr/bin/python3",
                    str(ROOT / "Tests/Linux/fixtures/linux_ui_backend_peer.py"), mode],
                    cwd=ROOT, env=environment, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("provisioning pending=guarded failure-log=retained polling=stable", result.stdout)

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
                environment["HOME"] = str(tools)
                fallback_record = tools / "unexpected-fallback"
                devpod = tools / "devpod"
                devpod.write_text('#!/bin/sh\nprintf unexpected > "$DEVSPACE_TEST_ZED_RECORD"\n')
                devpod.chmod(0o755)
                environment["DEVSPACE_TEST_ZED_RECORD"] = str(fallback_record)
                environment.pop("WAYLAND_DISPLAY", None)
                result = subprocess.run([
                    "xvfb-run", "-a", "/usr/bin/env", f"PATH={tools}", str(self.app_runner),
                    shutil.which("python3") or "/usr/bin/python3",
                    str(ROOT / "Tests/Linux/fixtures/linux_ui_backend_peer.py"), "zed-failure",
                ], cwd=ROOT, env=environment, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("zed-failure=visible terminal=round-trip actions=enabled", result.stdout)
                self.assertFalse(fallback_record.exists(), "explicit folder incorrectly used default-folder fallback")

    def test_zed_user_install_is_discovered_without_path_and_path_override_wins(self):
        for override in (False, True):
            with self.subTest(path_override=override), tempfile.TemporaryDirectory(dir=self.build) as temporary:
                home = Path(temporary)
                user_bin = home / ".local/bin"
                user_bin.mkdir(parents=True)
                path_bin = home / "tools"
                path_bin.mkdir()
                record = home / "editor-request"
                for directory, label in ((user_bin, "user"), (path_bin, "override")):
                    if directory == path_bin and not override:
                        continue
                    executable = directory / "zed"
                    executable.write_text(f'#!/bin/sh\nprintf "{label}:%s\\n" "$1" > "$DEVSPACE_TEST_ZED_RECORD"\n')
                    executable.chmod(0o755)
                environment = dict(os.environ, HOME=str(home), DEVSPACE_TEST_ZED_RECORD=str(record),
                                   G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
                environment.pop("WAYLAND_DISPLAY", None)
                result = subprocess.run([
                    "xvfb-run", "-a", "/usr/bin/env", f"PATH={path_bin}", str(self.app_runner),
                    shutil.which("python3") or "/usr/bin/python3",
                    str(ROOT / "Tests/Linux/fixtures/linux_ui_backend_peer.py"), "zed-success",
                ], cwd=ROOT, env=environment, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                label = "override" if override else "user"
                self.assertEqual(record.read_text(), f"{label}:ssh://fixture-pod.devpod/tmp/project\n")

    def test_nonexplicit_editor_failure_uses_devpod_fallback_without_blocking_terminal(self):
        for missing in (False, True):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory(dir=self.build) as temporary:
                home = Path(temporary)
                tools = home / "tools"
                tools.mkdir()
                if not missing:
                    executable = tools / "zed"
                    executable.write_text("#!/bin/sh\nexit 37\n")
                    executable.chmod(0o755)
                record = home / "editor-request"
                devpod = tools / "devpod"
                devpod.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$DEVSPACE_TEST_ZED_RECORD"\n')
                devpod.chmod(0o755)
                environment = dict(os.environ, HOME=str(home), DEVSPACE_TEST_ZED_RECORD=str(record),
                    DEVSPACE_TEST_ZED_EXPLICIT="false", G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
                environment.pop("WAYLAND_DISPLAY", None)
                result = subprocess.run([
                    "xvfb-run", "-a", "/usr/bin/env", f"PATH={tools}", str(self.app_runner),
                    shutil.which("python3") or "/usr/bin/python3",
                    str(ROOT / "Tests/Linux/fixtures/linux_ui_backend_peer.py"), "zed-success",
                ], cwd=ROOT, env=environment, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(record.read_text(), "up\n--ide\nzed\n--\nfixture-pod\n")

    def test_editor_failure_after_disconnect_cannot_launch_fallback(self):
        with tempfile.TemporaryDirectory(dir=self.build) as temporary:
            home = Path(temporary)
            tools = home / "tools"
            tools.mkdir()
            executable = tools / "zed"
            executable.write_text('#!/bin/sh\nprintf started > "$DEVSPACE_TEST_ZED_STARTED"\n/bin/sleep 0.3\nexit 37\n')
            executable.chmod(0o755)
            devpod = tools / "devpod"
            devpod.write_text('#!/bin/sh\nprintf unexpected > "$DEVSPACE_TEST_ZED_RECORD"\n')
            devpod.chmod(0o755)
            environment = dict(os.environ, HOME=str(home), DEVSPACE_TEST_ZED_RECORD=str(home / "fallback"),
                DEVSPACE_TEST_ZED_STARTED=str(home / "started"), DEVSPACE_TEST_ZED_EXPLICIT="false",
                G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
            environment.pop("WAYLAND_DISPLAY", None)
            result = subprocess.run([
                "xvfb-run", "-a", "/usr/bin/env", f"PATH={tools}", str(self.app_runner),
                shutil.which("python3") or "/usr/bin/python3",
                str(ROOT / "Tests/Linux/fixtures/linux_ui_backend_peer.py"), "zed-stale",
            ], cwd=ROOT, env=environment, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_existing_zed_session_activates_desktop_app_instead_of_provisioning(self):
        with tempfile.TemporaryDirectory(dir=self.build) as temporary:
            home = Path(temporary)
            tools = home / "tools"
            tools.mkdir()
            record = home / "editor-request"
            for name, value in (("activate-editor", "activated"), ("devpod", "wrong-default-folder")):
                executable = tools / name
                executable.write_text(f'#!/bin/sh\nprintf "{value}" > "$DEVSPACE_TEST_ZED_RECORD"\n')
                executable.chmod(0o755)
            applications = home / "share/applications"
            applications.mkdir(parents=True)
            (applications / "dev.zed.Zed.desktop").write_text(
                f"[Desktop Entry]\nType=Application\nName=Fixture Zed\nExec={tools / 'activate-editor'}\n")
            environment = dict(os.environ, HOME=str(home), XDG_DATA_HOME=str(home / "share"),
                XDG_DATA_DIRS=str(home / "empty"), DEVSPACE_TEST_ZED_RECORD=str(record),
                DEVSPACE_TEST_ZED_EXPLICIT="false", G_DEBUG="fatal-criticals", GDK_BACKEND="x11", GTK_A11Y="none")
            environment.pop("WAYLAND_DISPLAY", None)
            session = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(15)",
                                        "zed-ssh-session", "fixture-pod.devpod"])
            try:
                result = subprocess.run([
                    "xvfb-run", "-a", "/usr/bin/env", f"PATH={tools}", str(self.app_runner),
                    shutil.which("python3") or "/usr/bin/python3",
                    str(ROOT / "Tests/Linux/fixtures/linux_ui_backend_peer.py"), "zed-success",
                ], cwd=ROOT, env=environment, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(record.read_text(), "activated")
            finally:
                session.terminate()
                session.wait(timeout=5)

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
