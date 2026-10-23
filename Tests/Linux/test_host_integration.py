"""Opt-in checks that install the explicitly approved home-directory integration."""
import json
import os
import pty
import base64
from pathlib import Path
import selectors
import subprocess
import time
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BACKEND = Path(os.environ.get(
    "DEVSPACE_TEST_BACKEND", ROOT / "build/linux-dev/bin/DevSpaceLinuxBackend"
))
WORKSPACE = os.environ.get("DEVSPACE_HOST_INTEGRATION_WORKSPACE")
CHANNEL = os.environ.get("DEVSPACE_TEST_CHANNEL", "development")


@unittest.skipUnless(WORKSPACE, "opt-in authorized remote home integration")
class HostIntegrationTests(unittest.TestCase):
    def remote(self, command):
        result = subprocess.run(["/usr/bin/ssh", "-S", self.control_path, "-o", "ControlMaster=no",
            "-o", "ProxyCommand=/bin/false", "-o", "BatchMode=yes", f"{WORKSPACE}.devpod", command],
                                capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode, 0, "remote integration command failed")
        return result.stdout

    def setUp(self):
        self.process = subprocess.Popen([str(BACKEND), "--channel", CHANNEL],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.cleanup_backend)
        self.buffer = b""
        self.events = []
        self.sequence = 0
        ready = self.request("handshake")
        self.assertNotIn("notify_error", ready.get("payload", {}), "development listener port unavailable")
        self.request("poll")

    def cleanup_backend(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.write('{"version":1,"kind":"shutdown"}\n')
                self.process.stdin.flush()
                self.process.wait(timeout=15)
            except (OSError, subprocess.TimeoutExpired):
                self.process.terminate()
        self.process.communicate(timeout=10)

    def next_frame(self, timeout=30):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            with selectors.DefaultSelector() as selector:
                selector.register(self.process.stdout, selectors.EVENT_READ)
                self.assertTrue(selector.select(max(0, deadline - time.monotonic())), "host backend timed out")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            self.assertTrue(chunk, "host backend exited")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def request(self, kind, **payload):
        self.sequence += 1
        request_id = str(self.sequence)
        self.process.stdin.write(json.dumps({"version": 1, "id": request_id, "kind": kind, "payload": payload}) + "\n")
        self.process.stdin.flush()
        while True:
            frame = self.next_frame()
            if frame.get("id") == request_id:
                return frame
            self.events.append(frame)

    def event(self, kind, predicate=lambda frame: True):
        for frame in self.events:
            if frame["kind"] == kind and predicate(frame):
                return frame
        while True:
            frame = self.next_frame()
            self.events.append(frame)
            if frame["kind"] == kind and predicate(frame):
                return frame
            self.assertNotEqual(frame["kind"], "terminal_error", "real SSH transport failed")

    @staticmethod
    def unrelated_hooks(settings):
        result = {}
        for event, entries in settings.get("hooks", {}).items():
            kept = [entry for entry in entries if not any("/notify" in hook.get("command", "") and
                    "pod_id" in hook.get("command", "") for hook in entry.get("hooks", []))]
            if kept:
                result[event] = kept
        return result

    def test_two_real_shells_share_one_master_and_closing_one_preserves_the_other(self):
        def launch_shell(launch):
            master, slave = pty.openpty()
            child = subprocess.Popen([launch["executable"], *launch["arguments"]],
                                     stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            self.addCleanup(os.close, master)
            def close_child():
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=10)
            self.addCleanup(close_child)
            return master, child

        def round_trip(master, marker, setup=""):
            # Octal encoding makes an echoed command insufficient to pass.
            encoded = "".join(f"\\{byte:03o}" for byte in marker.encode())
            os.write(master, f"unset HISTFILE; {setup}printf '{encoded}\\n'\n".encode())
            output, deadline = b"", time.monotonic() + 20
            while marker.encode() not in output:
                with selectors.DefaultSelector() as selector:
                    selector.register(master, selectors.EVENT_READ)
                    self.assertTrue(selector.select(max(0, deadline - time.monotonic())),
                                    "real shared-master shell round-trip timed out")
                output += os.read(master, 65536)

        self.assertEqual(self.request("connect", workspace_id=WORKSPACE)["kind"], "completed")
        first = json.loads(self.event("terminal_launch")["payload"]["json"])
        first_fd, first_child = launch_shell(first)
        round_trip(first_fd, "DS_FIRST_READY")
        self.request("terminal_output", workspace_id=WORKSPACE, generation=first["generation"], pane_id=first["paneID"])
        self.event("terminal_ready")
        self.assertEqual(self.request("new_terminal", workspace_id=WORKSPACE)["kind"], "completed")
        second = json.loads(self.event("terminal_launch", lambda frame:
            json.loads(frame["payload"]["json"])["paneID"] != first["paneID"])["payload"]["json"])
        self.assertEqual(first["generation"], second["generation"])
        self.assertEqual([a for a in first["arguments"] if a.startswith("ControlPath=")],
                         [a for a in second["arguments"] if a.startswith("ControlPath=")])
        second_fd, second_child = launch_shell(second)
        round_trip(first_fd, "DS_FIRST_PRIVATE", "export DEVSPACE_ACCEPT_SHELL=first; ")
        round_trip(second_fd, "DS_SECOND_INDEPENDENT", 'test -z "${DEVSPACE_ACCEPT_SHELL-}" && ')
        first_child.terminate()
        first_child.wait(timeout=10)
        self.request("terminal_exit", workspace_id=WORKSPACE, generation=first["generation"],
                     pane_id=first["paneID"], exit_code="0", explicit_close="true")
        self.assertIsNone(second_child.poll(), "closing a sibling killed the remaining SSH client")
        round_trip(second_fd, "DS_SECOND_SURVIVED")
        self.assertEqual(self.request("disconnect", workspace_id=WORKSPACE)["kind"], "completed")
        status = subprocess.run(["devpod", "status", "--output", "json", "--timeout", "10s", "--", WORKSPACE],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(status.returncode, 0, "workspace status check failed")
        self.assertEqual(json.loads(status.stdout)["state"], "Running")

    def test_installs_hooks_preserves_settings_and_routes_real_helper_and_ded(self):
        self.assertEqual(self.request("connect", workspace_id=WORKSPACE)["kind"], "completed")
        launch = json.loads(self.event("terminal_launch")["payload"]["json"])
        self.control_path = next(arg.split("=", 1)[1] for arg in launch["arguments"] if arg.startswith("ControlPath="))
        read = 'if [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" ]; then cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; else printf "{}"; fi'
        before = json.loads(self.remote(read))
        self.assertEqual(self.request("install_hooks", workspace_id=WORKSPACE)["kind"], "completed")
        after = json.loads(self.remote(read))
        self.assertEqual({key: value for key, value in before.items() if key != "hooks"},
                         {key: value for key, value in after.items() if key != "hooks"})
        self.assertEqual(self.unrelated_hooks(before), self.unrelated_hooks(after))
        for name in ("Stop", "Notification", "PreToolUse"):
            self.assertTrue(after["hooks"][name])
        helper = self.remote('DEVSPACE_PROD_POD_FORWARD_PORT=1 ~/.devspace-notify Stop')
        self.assertIn("sent event=Stop", helper, "manual helper could not reach the development reverse tunnel")
        notification = self.event("platform_notify", lambda frame:
            frame["payload"].get("workspace_id") == WORKSPACE
            and frame["payload"].get("message") == "Claude finished")
        self.assertEqual(notification["payload"]["workspace_id"], WORKSPACE)
        self.assertEqual(notification["payload"]["message"], "Claude finished")
        self.remote("bash -ic 'DEVSPACE_PROD_POD_FORWARD_PORT=1 ded /tmp'")
        zed = self.event("platform_open_zed")
        self.assertEqual(zed["payload"]["url"], f"ssh://{WORKSPACE}.devpod/tmp")

        # Confirm output from a real SSH PTY before reporting readiness. The
        # octal marker is not present literally in command echo.
        master, slave = pty.openpty()
        terminal = subprocess.Popen([launch["executable"], *launch["arguments"]], stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        self.addCleanup(os.close, master)
        def close_terminal():
            if terminal.poll() is None:
                terminal.terminate()
            terminal.wait(timeout=10)
        self.addCleanup(close_terminal)
        os.write(master, b"unset HISTFILE; printf '\\104\\105\\126\\123\\120\\101\\103\\105\\137\\111\\115\\101\\107\\105\\137\\122\\105\\101\\104\\131\\n'\n")
        output = b""
        deadline = time.monotonic() + 15
        while b"DEVSPACE_IMAGE_READY" not in output:
            with selectors.DefaultSelector() as selector:
                selector.register(master, selectors.EVENT_READ)
                self.assertTrue(selector.select(max(0, deadline - time.monotonic())), "real image PTY produced no output")
            output += os.read(master, 65536)
        self.assertEqual(self.request("terminal_output", workspace_id=WORKSPACE, generation=launch["generation"],
            pane_id=launch["paneID"])["kind"], "snapshot")
        png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2ioAAAAASUVORK5CYII=")
        with tempfile.NamedTemporaryFile(prefix="devspace-paste-", suffix=".png", delete=False) as source:
            source.write(png)
            source_path = source.name
        self.addCleanup(lambda: Path(source_path).unlink(missing_ok=True))
        self.assertEqual(self.request("paste_image", workspace_id=WORKSPACE, generation=launch["generation"],
            pane_id=launch["paneID"], source_path=source_path)["kind"], "completed")
        self.assertFalse(Path(source_path).exists(), "local clipboard image was not cleaned up")
        injection = json.loads(self.event("terminal_inject", lambda frame:
            json.loads(frame["payload"]["json"]).get("message", "").startswith("Image pasted: "))["payload"]["json"])
        self.assertEqual(injection["paneID"], launch["paneID"])
        remote_path = injection["message"].removeprefix("Image pasted: ").strip()
        self.assertRegex(remote_path, r"^/tmp/devspace-paste-[A-Fa-f0-9-]+\.png$")
        try:
            self.assertEqual(base64.b64decode(self.remote(f"base64 -w0 {remote_path}")), png)
        finally:
            self.remote(f"rm -f -- {remote_path}")
        before_disconnect = json.loads(self.remote(read))
        self.assertEqual(self.request("disconnect", workspace_id=WORKSPACE)["kind"], "completed")
        deadline = time.monotonic() + 15
        while Path(self.control_path).exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(Path(self.control_path).exists(), "owned SSH master did not close")
        other_port, own_port = (8765, 8766) if CHANNEL == "development" else (8766, 8765)
        probe = read + "; printf '\\n__DEVSPACE_PEER__'; " + (
            f"if curl --noproxy '*' -fsS --max-time 1 -o /dev/null http://127.0.0.1:{other_port}/ 2>/dev/null; "
            "then printf yes; else printf no; fi; printf '\\n__DEVSPACE_OWN__'; "
            f"if curl --noproxy '*' -fsS --max-time 1 -o /dev/null http://127.0.0.1:{own_port}/ 2>/dev/null; "
            "then printf yes; else printf no; fi"
        )
        result = subprocess.run(["devpod", "ssh", "--command", probe, "--", WORKSPACE],
                                capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode, 0, "post-disconnect hook check failed")
        settings_text, ownership = result.stdout.rsplit("\n__DEVSPACE_PEER__", 1)
        peer, own = ownership.split("\n__DEVSPACE_OWN__")
        after_disconnect = json.loads(settings_text)
        self.assertEqual(own.strip(), "no", "disconnected channel's remote notification forward survived")
        self.assertTrue({k: v for k, v in before_disconnect.items() if k != "hooks"}
                        == {k: v for k, v in after_disconnect.items() if k != "hooks"},
                        "disconnect altered unrelated Claude settings")
        self.assertTrue(self.unrelated_hooks(before_disconnect) == self.unrelated_hooks(after_disconnect),
                        "disconnect altered unrelated hooks")
        has_managed = any("__devspace_resolve_port" in hook.get("command", "")
                          for entries in after_disconnect.get("hooks", {}).values()
                          for entry in entries for hook in entry.get("hooks", []))
        self.assertEqual(has_managed, peer.strip() == "yes",
                         "hooks must be removed unless the other channel still owns a live tunnel")
