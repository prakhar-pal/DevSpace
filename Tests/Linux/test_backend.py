"""Exercise the real Swift backend with a controlled DevPod executable."""
import json
import base64
import http.client
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import unittest
import time

ROOT = Path(__file__).resolve().parents[2]
BACKEND = Path(os.environ.get("DEVSPACE_TEST_BACKEND", ROOT / ".tmp/swift-linux-app/debug/DevSpaceLinuxBackend"))


@unittest.skipUnless(BACKEND.is_file(), "build DevSpaceLinuxBackend first")
class BackendIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / ".tmp")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        fake = self.directory / "devpod"
        fake.symlink_to(ROOT / "Tests/Linux/fixtures/devpod.py")
        env = dict(os.environ, PATH=str(self.directory) + os.pathsep + os.environ["PATH"],
                   DEVSPACE_TEST_STATE=str(self.directory / "state"),
                   XDG_CONFIG_HOME=str(self.directory / "config"))
        self.environment = env
        self.process = subprocess.Popen([str(BACKEND), "--channel", "development", "--notify-port", "0"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, env=env)
        self.addCleanup(self.cleanup_process)
        self.sequence = 0
        self.read_buffer = b""
        self.frames = []
        self.ready_response = self.request("handshake")
        self.assertEqual(self.ready_response["kind"], "ready")

    def cleanup_process(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.write('{"version":1,"kind":"shutdown"}\n')
                self.process.stdin.flush()
                self.process.wait(timeout=5)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                self.process.kill()
        self.process.communicate(timeout=5)

    def next_frame(self, timeout=5):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.read_buffer:
            with selectors.DefaultSelector() as selector:
                selector.register(self.process.stdout, selectors.EVENT_READ)
                self.assertTrue(selector.select(max(0, deadline - time.monotonic())), "backend frame timed out")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            self.assertTrue(chunk, "backend exited before response")
            self.read_buffer += chunk
        line, self.read_buffer = self.read_buffer.split(b"\n", 1)
        return json.loads(line)

    def response_for(self, request_id):
        for index, frame in enumerate(self.frames):
            if frame.get("id") == request_id:
                return self.frames.pop(index)
        while True:
            frame = self.next_frame()
            if frame.get("id") == request_id:
                return frame
            self.frames.append(frame)

    def request(self, kind, **payload):
        self.sequence += 1
        request = {"version": 1, "id": str(self.sequence), "kind": kind, "payload": payload}
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        return self.response_for(request["id"])

    def snapshot_request(self, kind, **payload):
        response = self.request(kind, **payload)
        self.assertEqual(response["kind"], "snapshot")
        return json.loads(response["payload"]["json"])

    def test_poll_and_stop_observe_real_command_results(self):
        snapshot = json.loads(self.request("poll")["payload"]["json"])
        self.assertEqual(snapshot["workspaces"][0]["state"], "Running")
        self.assertEqual(self.request("stop", workspace_id="pod")["kind"], "completed")
        snapshot = json.loads(self.request("poll")["payload"]["json"])
        self.assertEqual(snapshot["workspaces"][0]["state"], "Stopped")

    def test_external_stop_emits_one_lifecycle_notification_and_ignores_transient_status(self):
        self.request("poll")
        self.assertFalse(any(frame["kind"] == "platform_notify" for frame in self.frames))
        (self.directory / "state").write_text("Busy")
        self.request("poll")
        self.assertFalse(any(frame["kind"] == "platform_notify" for frame in self.frames))
        (self.directory / "state").write_text("Stopped")
        self.request("poll")
        self.request("poll")
        events = [frame for frame in self.frames if frame["kind"] == "platform_notify"]
        self.assertEqual(len(events), 1, "external shutdown must notify exactly once")
        self.assertEqual(events[0]["payload"]["workspace_id"], "pod")
        self.assertEqual(events[0]["payload"]["message"], "Workspace stopped")
        self.assertEqual(events[0]["payload"]["event"], "stopped")

    def test_start_command_does_not_announce_ready_without_ssh_output(self):
        (self.directory / "state").write_text("Stopped")
        self.request("poll")
        self.assertEqual(self.request("start", workspace_id="pod")["kind"], "completed")
        self.request("poll")
        self.assertFalse(any(frame["kind"] == "platform_notify" for frame in self.frames),
                         "provisioning completion is not terminal readiness")

    def test_external_restart_notifies_without_waking_or_opening_another_session(self):
        (self.directory / "state").write_text("Stopped")
        self.request("poll")
        (self.directory / "state").write_text("Running")
        self.request("poll")
        self.assertFalse(any(frame["kind"] == "platform_notify" for frame in self.frames),
                         "first Running sample after stop is not confirmed")
        self.request("poll")
        events = [frame for frame in self.frames if frame["kind"] == "platform_notify"]
        self.assertEqual(len(events), 1, "external restart must notify without an owned SSH session")
        self.assertEqual(events[0]["payload"]["message"], "Workspace started")
        self.assertEqual(events[0]["payload"]["event"], "started")
        self.assertFalse(any(frame["kind"] == "terminal_launch" for frame in self.frames))

    def test_single_running_blip_after_stop_does_not_announce_a_restart(self):
        (self.directory / "state").write_text("Stopped")
        self.request("poll")
        (self.directory / "state").write_text("Running")
        snapshot = self.snapshot_request("poll")
        self.assertEqual(snapshot["workspaces"][0]["state"], "Loading")
        (self.directory / "state").write_text("Stopped")
        self.request("poll")
        self.assertFalse(any(frame["kind"] == "platform_notify" for frame in self.frames))

    def test_selection_is_reflected_in_snapshot(self):
        self.request("poll")
        response = self.request("select", workspace_id="pod")
        self.assertEqual(response["kind"], "snapshot")
        self.assertEqual(json.loads(response["payload"]["json"])["selectedID"], "pod")

    def test_editor_request_preserves_explicit_folder_and_rejects_stopped_or_unknown_workspace(self):
        self.request("poll")
        self.assertEqual(self.request("open_zed", workspace_id="pod", directory="/tmp/a b/α")["kind"], "completed")
        events = [frame for frame in self.frames if frame["kind"] == "platform_open_zed"]
        self.assertEqual(events[-1]["payload"]["url"], "ssh://pod.devpod/tmp/a%20b/%CE%B1")
        self.assertEqual(events[-1]["payload"]["explicit_directory"], "true")
        self.assertEqual(self.request("open_zed", workspace_id="pod", directory="/tmp/a b/α",
                                      explicit_directory="false")["kind"], "completed")
        events = [frame for frame in self.frames if frame["kind"] == "platform_open_zed"]
        self.assertEqual(events[-1]["payload"]["explicit_directory"], "false",
                         "inferred OSC 7 directory must retain keyboard-launch fallback semantics")
        self.assertEqual(self.request("open_zed", workspace_id="pod", directory="relative")["kind"], "error")
        self.assertEqual(self.request("open_zed", workspace_id="unknown")["kind"], "error")
        (self.directory / "state").write_text("Stopped")
        self.request("poll")
        self.assertEqual(self.request("open_zed", workspace_id="pod")["kind"], "error")

    def test_path_probe_repairs_login_path_without_protocol_frames(self):
        visible = self.directory / "visible-bin"
        visible.mkdir()
        (visible / "devpod").write_text("#!/bin/sh\nexit 0\n")
        (visible / "devpod").chmod(0o755)
        shell = self.directory / "login-shell"
        shell.write_text("#!/bin/sh\nprintf '__DEVSPACE_PATH_START__%s/custom/bin:/usr/bin:/bin__DEVSPACE_PATH_END__\\n' \"$HOME\"\n")
        shell.chmod(0o755)
        env = dict(self.environment, PATH=f"{visible}:/usr/bin:/bin", HOME=str(self.directory), SHELL=str(shell))
        result = subprocess.run([str(BACKEND), "--print-path"], stdin=subprocess.DEVNULL, env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(self.directory / "custom/bin"), result.stdout.strip().split(":"))
        self.assertEqual(result.stdout.strip().split(":")[0], str(visible))
        self.assertNotIn('"version"', result.stdout)

    def test_path_probe_does_not_wait_for_background_stdout_owner(self):
        shell = self.directory / "background-login-shell"
        shell.write_text("#!/bin/sh\n/bin/sleep 4 &\nprintf '__DEVSPACE_PATH_START__/profile/bin:/usr/bin:/bin__DEVSPACE_PATH_END__\\n'\n")
        shell.chmod(0o755)
        started = time.monotonic()
        result = subprocess.run([str(BACKEND), "--print-path"],
                                stdin=subprocess.DEVNULL,
                                env=dict(self.environment, SHELL=str(shell)),
                                capture_output=True, text=True, timeout=6)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("/profile/bin", result.stdout.strip().split(":"))
        self.assertLess(time.monotonic() - started, 2,
                        "PATH discovery waited for a background stdout owner")

    def test_login_shell_cannot_consume_backend_handshake(self):
        shell = self.directory / "reading-login-shell"
        shell.write_text("#!/bin/sh\nread ignored || :\nprintf '__DEVSPACE_PATH_START__/usr/bin:/bin__DEVSPACE_PATH_END__\\n'\n")
        shell.chmod(0o755)
        requests = "".join(json.dumps({"version": 1, "id": str(index), "kind": kind}) + "\n"
                           for index, kind in enumerate(("handshake", "shutdown")))
        result = subprocess.run([str(BACKEND), "--channel", "development", "--notify-port", "0"],
                                input=requests, env=dict(self.environment, SHELL=str(shell)),
                                capture_output=True, text=True, timeout=5)
        frames = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertIn("ready", [frame["kind"] for frame in frames], result.stderr)

    def test_stalled_frontend_output_does_not_block_control_input(self):
        import threading
        finished = threading.Event()
        def submit():
            try:
                for number in range(6000):
                    self.process.stdin.write(json.dumps({"version": 1, "id": str(number), "kind": "ping"}) + "\n")
                self.process.stdin.flush()
            finally:
                finished.set()
        writer = threading.Thread(target=submit, daemon=True)
        writer.start()
        completed = finished.wait(2)
        # Drain in either case so the diagnostic does not strand a child or
        # race cleanup against a thread still using its stdin.
        drained = 0
        while not finished.is_set():
            self.next_frame()
            drained += 1
        writer.join()
        for _ in range(6000 - drained):
            self.next_frame()
        self.assertTrue(completed, "backend stopped consuming controls when its output pipe filled")

    def test_malformed_http_length_does_not_crash_backend(self):
        import socket
        import threading
        # Drain crash diagnostics so a fatal-error backtrace cannot fill stderr
        # and falsely appear to be a live backend.
        threading.Thread(target=self.process.stderr.read, daemon=True).start()
        port = int(self.ready_response["payload"]["notify_port"])
        for length in ("", "-1", "abc", "999999999999999999999999999"):
            with socket.create_connection(("127.0.0.1", port), timeout=2) as peer:
                peer.sendall(("POST /notify HTTP/1.1\r\nContent-Length: " + length + "\r\n\r\n").encode())
                peer.settimeout(2)
                try:
                    peer.recv(1024)
                except ConnectionResetError:
                    pass
            self.assertEqual(self.request("ping")["kind"], "pong")

    def test_alias_edit_is_persisted_and_loaded_after_backend_restart(self):
        self.request("poll")
        response = self.request("alias", workspace_id="pod", name="Workspace α / with spaces")
        self.assertEqual(response["kind"], "snapshot")
        layout = json.loads(response["payload"]["json"])["layout"]
        self.assertEqual(layout["aliases"]["pod"], "Workspace α / with spaces")
        self.assertEqual(self.request("shutdown")["kind"], "stopped")
        self.assertEqual(self.process.wait(timeout=5), 0)
        self.process.communicate(timeout=5)
        self.process = subprocess.Popen([str(BACKEND), "--channel", "development", "--notify-port", "0"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, env=self.environment)
        self.read_buffer = b""
        self.frames = []
        self.assertEqual(self.request("handshake")["kind"], "ready")
        snapshot = json.loads(self.request("snapshot")["payload"]["json"])
        self.assertEqual(snapshot["layout"]["aliases"]["pod"], "Workspace α / with spaces")

    def test_sidebar_visibility_and_order_edits_preserve_selection(self):
        (self.directory / "extra-pod").touch()
        self.request("poll")
        self.request("select", workspace_id="pod")
        hidden = self.snapshot_request("hide", workspace_id="pod")
        self.assertEqual(hidden["layout"]["hidden"], ["pod"])
        self.assertEqual(hidden["selectedID"], "pod")
        shown = self.snapshot_request("show", workspace_id="pod")
        self.assertEqual(shown["layout"]["hidden"], [])
        reordered = self.snapshot_request("move_down", workspace_id="pod")
        self.assertEqual(reordered["layout"]["order"], ["other", "pod"])
        collapsed = self.snapshot_request("collapse_hidden")
        self.assertTrue(collapsed["layout"]["hidden_collapsed"])
        self.request("shutdown")
        self.process.communicate(timeout=5)
        self.process = subprocess.Popen([str(BACKEND), "--channel", "development", "--notify-port", "0"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, env=self.environment)
        self.read_buffer = b""
        self.frames = []
        self.assertEqual(self.request("handshake")["kind"], "ready")
        restored = self.snapshot_request("snapshot")["layout"]
        self.assertEqual(restored["order"], ["other", "pod"])
        self.assertTrue(restored["hidden_collapsed"])

    def test_alias_edit_rejects_unknown_workspace_without_changing_layout(self):
        self.request("poll")
        before = json.loads(self.request("snapshot")["payload"]["json"])["layout"]
        self.assertEqual(self.request("alias", workspace_id="missing", name="bad")["kind"], "error")
        after = json.loads(self.request("snapshot")["payload"]["json"])["layout"]
        self.assertEqual(before, after)

    def test_invalid_id_returns_error_and_backend_remains_available(self):
        response = self.request("delete", workspace_id="--all")
        self.assertEqual(response["kind"], "error")
        self.assertEqual(self.request("ping")["kind"], "pong")

    def test_shutdown_acknowledges_and_exits(self):
        self.assertEqual(self.request("shutdown")["kind"], "stopped")
        self.assertEqual(self.process.wait(timeout=5), 0)

    def begin_slow_command(self, kind="start", **payload):
        (self.directory / "slow").touch()
        self.sequence += 1
        self.process.stdin.write(json.dumps({"version": 1, "id": str(self.sequence),
            "kind": kind, "payload": payload or {"workspace_id": "pod"}}) + "\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + 5
        while not (self.directory / "started").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue((self.directory / "started").exists())

    def test_shutdown_waits_for_inflight_command_cleanup(self):
        self.begin_slow_command()
        self.assertEqual(self.request("shutdown")["kind"], "stopped")
        self.assertTrue((self.directory / "cleaned").exists(), "shutdown acknowledged before command cleanup")

    def test_running_status_during_start_cannot_open_ssh_before_completion(self):
        (self.directory / "state").write_text("Stopped")
        self.request("poll")
        self.begin_slow_command()
        operation_id = str(self.sequence)
        (self.directory / "state").write_text("Running")
        self.request("poll")
        self.request("poll")
        response = self.request("snapshot")
        snapshot = json.loads(response["payload"]["json"])
        self.assertEqual(snapshot["operations"][0]["kind"], "start")
        self.assertNotIn("pod", json.loads(response["payload"]["connections"]),
                         "Running status opened SSH while Start was still provisioning")
        self.request("cancel", request_id=operation_id)
        self.assertEqual(self.response_for(operation_id)["kind"], "cancelled")
        self.request("poll")
        self.assertNotIn("pod", json.loads(self.request("snapshot")["payload"]["connections"]))

    def test_connect_and_reload_reject_busy_workspaces(self):
        self.request("poll")
        self.begin_slow_command()
        self.assertEqual(self.request("connect", workspace_id="pod")["kind"], "error")
        self.assertEqual(self.request("reconnect", workspace_id="pod")["kind"], "error")
        self.assertFalse(any(frame["kind"] == "terminal_launch" for frame in self.frames))

    def test_cancel_operation_waits_for_cleanup_and_keeps_polling_usable(self):
        self.begin_slow_command()
        running_request = str(self.sequence)
        response = self.request("cancel", request_id=running_request)
        self.assertEqual(response["kind"], "completed", response)
        cancelled = self.response_for(running_request)
        self.assertEqual(cancelled["id"], running_request)
        self.assertEqual(cancelled["kind"], "cancelled", cancelled)
        self.assertTrue((self.directory / "cleaned").exists(), "cancellation completed before child cleanup")
        self.assertEqual(self.request("ping")["kind"], "pong")
        snapshot = self.snapshot_request("poll")
        self.assertEqual(snapshot["workspaces"][0]["id"], "pod")
        (self.directory / "slow").unlink()
        self.assertEqual(self.request("start", workspace_id="pod")["kind"], "completed")

    def test_provisioning_output_is_live_and_cancellation_state_is_shared(self):
        self.begin_slow_command()
        running_request = str(self.sequence)
        deadline = time.monotonic() + 5
        while True:
            snapshot = self.snapshot_request("snapshot")
            active = snapshot.get("operations", [])
            if active and "Preparing λ界🙂" in active[0]["output"] and "Checking provider" in active[0]["output"]:
                break
            self.assertLess(time.monotonic(), deadline, "no live provisioning output before completion")
            time.sleep(0.02)
        self.assertEqual(active[0]["id"], running_request)
        self.assertEqual(active[0]["workspaceID"], "pod")
        self.assertEqual(active[0]["state"], "running")
        self.assertEqual(self.request("cancel", request_id=running_request)["kind"], "completed")
        self.assertEqual(self.snapshot_request("snapshot")["operations"][0]["state"], "cancelling")
        self.assertEqual(self.response_for(running_request)["kind"], "cancelled")
        self.assertEqual(self.snapshot_request("snapshot")["operations"], [])

    def test_conflicting_operation_is_rejected_without_queueing(self):
        self.begin_slow_command()
        running_request = str(self.sequence)
        conflict = self.request("stop", workspace_id="pod")
        self.assertEqual(conflict["kind"], "error")
        self.assertIn("already active", conflict["payload"]["message"])
        self.assertEqual(self.request("cancel", request_id=running_request)["kind"], "completed")
        self.assertEqual(self.response_for(running_request)["kind"], "cancelled")

    def test_log_chunks_preserve_unicode_with_interleaved_stderr(self):
        (self.directory / "split-output").touch()
        self.begin_slow_command()
        deadline = time.monotonic() + 5
        while True:
            active = self.snapshot_request("snapshot").get("operations", [])
            if active and "Checking provider" in active[0]["output"]:
                break
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.02)
        self.assertIn("λ界🙂", active[0]["output"])
        self.assertNotIn("�", active[0]["output"])

    def test_operation_log_retains_only_a_bounded_tail(self):
        (self.directory / "large-output").touch()
        self.begin_slow_command()
        deadline = time.monotonic() + 5
        while True:
            active = self.snapshot_request("snapshot").get("operations", [])
            if active and "Preparing λ界🙂" in active[0]["output"]:
                break
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.02)
        self.assertLessEqual(len(active[0]["output"].encode()), 16384)

    def test_successful_recreate_restores_connection_intent_only_after_running_poll(self):
        self.request("poll")
        self.request("disconnect", workspace_id="pod")
        self.assertEqual(self.request("recreate", workspace_id="pod")["kind"], "completed")
        self.request("poll")
        snapshot = self.request("snapshot")
        self.assertIn("pod", json.loads(snapshot["payload"]["connections"]),
                      "successful recreation left the workspace disconnected")

    def test_creation_selects_discovered_workspace_and_rejects_existing_id(self):
        self.request("poll")
        duplicate = self.request("create", repository="https://example.invalid/new.git", workspace_id="pod")
        self.assertEqual(duplicate["kind"], "error")
        self.assertIn("already exists", duplicate["payload"]["message"])
        self.assertFalse((self.directory / "created.json").exists())
        created = self.request("create", repository="https://example.invalid/new.git", workspace_id="new-pod")
        self.assertEqual(created["kind"], "completed")
        snapshot = self.snapshot_request("poll")
        self.assertEqual(snapshot["selectedID"], "new-pod")
        self.assertIn("new-pod", [workspace["id"] for workspace in snapshot["workspaces"]])

    def test_cancel_creation_waits_for_cleanup_and_allows_another_creation(self):
        self.begin_slow_command("create", repository="https://example.invalid/new.git", workspace_id="new-pod")
        creation_id = str(self.sequence)
        self.assertEqual(self.request("cancel", request_id=creation_id)["kind"], "completed")
        self.assertEqual(self.response_for(creation_id)["kind"], "cancelled")
        self.assertTrue((self.directory / "cleaned").exists())
        self.assertFalse((self.directory / "created.json").exists())
        (self.directory / "slow").unlink()
        self.assertEqual(self.request("create", repository="https://example.invalid/new.git")["kind"], "completed")
        snapshot = self.snapshot_request("poll")
        self.assertEqual(snapshot["selectedID"], "generated-pod")

    def begin_delayed_poll(self):
        (self.directory / "slow-status").touch()
        self.sequence += 1
        request_id = str(self.sequence)
        self.process.stdin.write(json.dumps({"version": 1, "id": request_id, "kind": "poll"}) + "\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + 5
        while not (self.directory / "status-started").exists():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        return request_id

    def test_poll_started_before_stop_cannot_publish_pre_stop_state(self):
        poll_id = self.begin_delayed_poll()
        self.assertEqual(self.request("stop", workspace_id="pod")["kind"], "completed")
        snapshot = json.loads(self.response_for(poll_id)["payload"]["json"])
        self.assertEqual(snapshot["workspaces"][0]["state"], "Stopped")

    def test_selection_does_not_wait_for_a_slow_status_poll(self):
        self.request("poll")
        poll_id = self.begin_delayed_poll()
        before = time.monotonic()
        self.assertEqual(self.snapshot_request("select", workspace_id="pod")["selectedID"], "pod")
        self.assertLess(time.monotonic() - before, 0.3)
        self.response_for(poll_id)

    def test_workspace_command_cannot_consume_frontend_protocol_stdin(self):
        (self.directory / "read-stdin").touch()
        self.begin_slow_command()
        deadline = time.monotonic() + 1
        while not (self.directory / "child-input").exists():
            self.assertLess(time.monotonic(), deadline, "workspace command inherited the private protocol pipe")
            time.sleep(0.01)
        self.assertEqual((self.directory / "child-input").read_text(), "")
        self.assertEqual(self.request("ping")["kind"], "pong")

    def test_authenticated_notification_sets_badge_and_emits_platform_effect(self):
        (self.directory / "extra-pod").touch()
        self.assertEqual(self.snapshot_request("poll")["selectedID"], "pod")
        self.snapshot_request("select", workspace_id="other")
        port = int(self.ready_response["payload"].get("notify_port", "0"))
        self.assertGreater(port, 0, "backend did not start a notification listener")
        token_file = self.directory / "config/devspace/notify-token"
        token = token_file.read_text().strip()
        self.assertEqual(token_file.stat().st_mode & 0o777, 0o600)
        def post(workspace, supplied_token):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            try:
                connection.request("POST", "/notify", body=json.dumps({"pod_id": workspace,
                    "event": "Stop", "token": supplied_token}))
                self.assertEqual(connection.getresponse().status, 204)
            finally:
                connection.close()
        post("pod", "WRONG")
        self.assertEqual(self.snapshot_request("snapshot")["badges"], [])
        post("pod", token)
        self.assertEqual(self.snapshot_request("snapshot")["badges"], ["pod"])
        effects = [frame for frame in self.frames if frame["kind"] == "platform_notify"]
        self.assertEqual(len(effects), 1)
        self.assertEqual(effects[0]["payload"]["workspace_id"], "pod")
        self.assertEqual(effects[0]["payload"]["message"], "Claude finished")
        self.assertEqual(self.snapshot_request("select", workspace_id="pod")["badges"], [])
        post("unknown", token)
        self.assertEqual(self.snapshot_request("snapshot")["badges"], [])
        self.assertEqual(len([frame for frame in self.frames if frame["kind"] == "platform_notify"]), 1)

    def test_listener_bind_failure_does_not_disable_backend_actions(self):
        port = self.ready_response["payload"]["notify_port"]
        input_frames = [{"version": 1, "id": "ready", "kind": "handshake"},
                        {"version": 1, "id": "ping", "kind": "ping"},
                        {"version": 1, "id": "stop", "kind": "shutdown"}]
        result = subprocess.run([str(BACKEND), "--channel", "development", "--notify-port", port],
            input="".join(json.dumps(frame) + "\n" for frame in input_frames),
            capture_output=True, text=True, env=self.environment, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        frames = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([frame["kind"] for frame in frames], ["ready", "pong", "stopped"])
        self.assertIn("notify_error", frames[0]["payload"])
        token = (self.directory / "config/devspace/notify-token").read_text().strip()
        self.assertNotIn(token, result.stderr)

    def test_authenticated_ded_emits_one_zed_url_for_a_running_known_workspace(self):
        self.request("poll")
        port = int(self.ready_response["payload"]["notify_port"])
        token = (self.directory / "config/devspace/notify-token").read_text().strip()
        def post(workspace, supplied_token, path="/workspace/a b/α"):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            try:
                connection.request("POST", "/dide", body=json.dumps({"pod_id": workspace,
                    "path_b64": base64.b64encode(path.encode()).decode(), "token": supplied_token}))
                self.assertEqual(connection.getresponse().status, 204)
            finally:
                connection.close()
            self.request("ping")
        post("pod", "wrong")
        post("unknown", token)
        self.assertEqual([frame for frame in self.frames if frame["kind"] == "platform_open_zed"], [])
        post("pod", token)
        effects = [frame for frame in self.frames if frame["kind"] == "platform_open_zed"]
        self.assertEqual(len(effects), 1, "authenticated ded did not reach the desktop adapter")
        self.assertEqual(effects[0]["payload"], {"workspace_id": "pod", "url": "ssh://pod.devpod/workspace/a%20b/%CE%B1",
                                               "explicit_directory": "true"})
        self.request("stop", workspace_id="pod")
        self.request("poll")
        post("pod", token)
        self.assertEqual(len([frame for frame in self.frames if frame["kind"] == "platform_open_zed"]), 1,
                         "ded must not wake a stopped workspace")

    def test_invalid_claude_settings_do_not_block_independent_shell_integration(self):
        self.request("poll")
        remote_home = self.directory / "remote-home"
        settings = remote_home / ".claude/settings.json"
        settings.parent.mkdir(parents=True)
        original = "{broken settings"
        settings.write_text(original)
        response = self.request("install_hooks", workspace_id="pod")
        self.assertEqual(response["kind"], "error")
        self.assertEqual(settings.read_text(), original)
        self.assertTrue((remote_home / ".bashrc").is_file(), "Claude hook failure prevented shell integration")
        self.assertIn("ded()", (remote_home / ".bashrc").read_text())

    def test_hook_installation_preserves_settings_and_is_idempotent(self):
        self.request("poll")
        remote_home = self.directory / "remote-home"
        settings = remote_home / ".claude/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({"permissions": {"allow": ["Bash(git:*)"]},
            "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo unrelated"}]}]}}))
        for _ in range(2):
            self.assertEqual(self.request("install_hooks", workspace_id="pod")["kind"], "completed")
        self.assertFalse(any(frame["kind"] == "platform_info" for frame in self.frames),
                         "routine hook installation should be silent")
        merged = json.loads(settings.read_text())
        self.assertEqual(merged["permissions"], {"allow": ["Bash(git:*)"]})
        self.assertEqual(len(merged["hooks"]["Stop"]), 2)
        self.assertEqual(merged["hooks"]["Stop"][0]["hooks"][0]["command"], "echo unrelated")
        self.assertTrue(os.access(remote_home / ".devspace-notify", os.X_OK))
        self.assertIn("ded()", (remote_home / ".bashrc").read_text())
        self.assertEqual((remote_home / ".bashrc").read_text().count("# >>> devspace shell integration >>>"), 1)
        self.assertEqual(self.request("install_hooks", workspace_id="unknown")["kind"], "error")

    def test_image_upload_rejects_arbitrary_files_and_stale_panes_without_deleting_them(self):
        source = self.directory / "private.png"
        source.write_bytes(b"\x89PNG\r\n\x1a\n")
        response = self.request("paste_image", workspace_id="pod", generation="00000000-0000-0000-0000-000000000001",
            pane_id="00000000-0000-0000-0000-000000000002", source_path=str(source))
        self.assertEqual(response["kind"], "error")
        self.assertIn("image", response["payload"]["message"].lower())
        self.assertNotIn("unsupported command", response["payload"]["message"])
        self.assertTrue(source.is_file())

    def test_malformed_input_releases_inflight_command_before_exit(self):
        self.begin_slow_command()
        self.process.stdin.write("not json\n")
        self.process.stdin.flush()
        self.assertEqual(self.process.wait(timeout=5), 1)
        self.assertTrue((self.directory / "cleaned").exists(), "protocol failure abandoned command cleanup")

    def test_duplicate_handshake_releases_inflight_command_before_exit(self):
        self.begin_slow_command()
        self.process.stdin.write(json.dumps({"version": 1, "id": "duplicate", "kind": "handshake"}) + "\n")
        self.process.stdin.flush()
        self.assertEqual(self.process.wait(timeout=5), 1)
        self.assertTrue((self.directory / "cleaned").exists(), "duplicate handshake abandoned command cleanup")

    def test_closed_frontend_output_releases_inflight_command_before_exit(self):
        self.begin_slow_command()
        self.process.stdout.close()
        self.process.stdout = None
        self.process.stdin.write(json.dumps({"version": 1, "id": "closed-output", "kind": "ping"}) + "\n")
        self.process.stdin.flush()
        self.assertEqual(self.process.wait(timeout=5), 1)
        self.assertTrue((self.directory / "cleaned").exists(), "broken output pipe abandoned command cleanup")

    def test_partial_frame_at_eof_is_rejected_after_command_cleanup(self):
        self.begin_slow_command()
        self.process.stdin.write('{"version":1,"kind":')
        self.process.stdin.close()
        self.process.stdin = None
        self.assertEqual(self.process.wait(timeout=5), 1)
        self.assertTrue((self.directory / "cleaned").exists(), "partial frame abandoned command cleanup")

    def test_oversized_unterminated_frame_is_rejected(self):
        self.process.stdin.write("x" * (1_048_576 + 1))
        self.process.stdin.flush()
        self.assertEqual(self.process.wait(timeout=5), 1)

    def test_new_terminal_requires_existing_ready_master_without_provisioning(self):
        self.request("poll")
        self.request("disconnect", workspace_id="pod")
        response = self.request("new_terminal", workspace_id="pod")
        self.assertEqual(response["kind"], "error")
        self.assertIn("ready SSH session", response["payload"]["message"])
        self.assertFalse(any(frame["kind"] == "terminal_launch" for frame in self.frames))

    def test_connect_rejects_stopped_workspace_without_starting_ssh(self):
        self.request("stop", workspace_id="pod")
        self.request("poll")
        response = self.request("connect", workspace_id="pod")
        self.assertEqual(response["kind"], "error")
        self.assertIn("not running", response["payload"]["message"])

    def test_failed_ssh_retries_are_bounded_and_manual_connect_starts_a_new_budget(self):
        self.request("poll")
        def wait_for_failures(count):
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                self.request("ping")
                if len([frame for frame in self.frames if frame["kind"] == "terminal_error"]) >= count:
                    return
                time.sleep(0.02)
            self.fail(f"did not observe {count} bounded SSH failures")
        wait_for_failures(3)
        for _ in range(3):
            self.request("poll")
        self.assertEqual(len([frame for frame in self.frames if frame["kind"] == "terminal_error"]), 3,
                         "polling restarted an exhausted SSH connection")
        snapshot = self.request("snapshot")
        self.assertEqual(json.loads(snapshot["payload"]["connections"])["pod"], "failed")
        self.assertEqual(self.request("connect", workspace_id="pod")["kind"], "completed")
        wait_for_failures(6)

    def test_disconnect_invalidates_a_scheduled_ssh_retry(self):
        self.request("poll")
        deadline = time.monotonic() + 3
        while not any(frame["kind"] == "terminal_error" for frame in self.frames) and time.monotonic() < deadline:
            self.request("ping")
            time.sleep(0.01)
        self.assertEqual(self.request("disconnect", workspace_id="pod")["kind"], "completed")
        time.sleep(0.7)
        self.request("poll")
        self.assertEqual(len([frame for frame in self.frames if frame["kind"] == "terminal_error"]), 1,
                         "a cancelled retry or subsequent poll reopened SSH")

    def test_retry_checks_fresh_status_before_attempting_ssh(self):
        self.request("poll")
        deadline = time.monotonic() + 3
        while not any(frame["kind"] == "terminal_error" for frame in self.frames) and time.monotonic() < deadline:
            self.request("ping")
            time.sleep(0.01)
        # No status poll is sent: recovery must independently learn that the
        # provider stopped the pod during its backoff instead of waking it.
        (self.directory / "state").write_text("Stopped")
        time.sleep(0.7)
        self.request("ping")
        snapshot = self.request("snapshot")
        self.assertNotIn("pod", json.loads(snapshot["payload"]["connections"]))
        self.assertEqual(len([frame for frame in self.frames if frame["kind"] == "terminal_error"]), 1)
