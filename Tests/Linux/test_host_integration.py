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
BACKEND = ROOT / ".tmp/swift-linux-app/debug/DevSpaceLinuxBackend"
WORKSPACE = os.environ.get("DEVSPACE_HOST_INTEGRATION_WORKSPACE")


@unittest.skipUnless(WORKSPACE, "opt-in authorized remote home integration")
class HostIntegrationTests(unittest.TestCase):
    def remote(self, command):
        result = subprocess.run(["/usr/bin/ssh", "-S", self.control_path, "-o", "ControlMaster=no",
            "-o", "ProxyCommand=/bin/false", "-o", "BatchMode=yes", f"{WORKSPACE}.devpod", command],
                                capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode, 0, "remote integration command failed")
        return result.stdout

    def setUp(self):
        self.process = subprocess.Popen([str(BACKEND), "--channel", "development"],
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

    def event(self, kind):
        for frame in self.events:
            if frame["kind"] == kind:
                return frame
        while True:
            frame = self.next_frame()
            self.events.append(frame)
            if frame["kind"] == kind:
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
        self.remote('DEVSPACE_PROD_POD_FORWARD_PORT=1 ~/.devspace-notify Stop')
        notification = self.event("platform_notify")
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
        injection = json.loads(self.event("terminal_inject")["payload"]["json"])
        self.assertEqual(injection["paneID"], launch["paneID"])
        remote_path = injection["message"].removeprefix("Image pasted: ").strip()
        self.assertRegex(remote_path, r"^/tmp/devspace-paste-[A-Fa-f0-9-]+\.png$")
        try:
            self.assertEqual(base64.b64decode(self.remote(f"base64 -w0 {remote_path}")), png)
        finally:
            self.remote(f"rm -f -- {remote_path}")
