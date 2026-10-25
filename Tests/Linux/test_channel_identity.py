"""Opt-in coexistence check on a private X display and D-Bus session."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
PREFIX = Path(os.environ.get("DEVSPACE_TEST_FRONTEND_PREFIX", ROOT / "build/linux-dev-bundle"))
APP_PATHS = {
    "development": PREFIX / "bin/DevSpaceDev",
    "production": PREFIX / "bin/DevSpace",
}
IDS = {"development": "com.prakharp.devspace.dev", "production": "com.prakharp.devspace"}


@unittest.skipUnless(os.environ.get("DEVSPACE_TEST_ISOLATED_GUI") == "1"
                     and all(path.is_file() for path in APP_PATHS.values()),
                     "opt-in private-display/private-bus native check")
class ChannelIdentityTests(unittest.TestCase):
    def owners(self):
        result = subprocess.run(["busctl", "--user", "list", "--no-legend", "--no-pager"],
                                capture_output=True, text=True, check=True, timeout=5)
        return {parts[0]: int(parts[1]) for row in result.stdout.splitlines()
                if len(parts := row.split()) > 1 and parts[0] in IDS.values()}

    def wait_for(self, predicate, process, message, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.assertIsNone(process.poll(), message)
            if predicate():
                return
            time.sleep(0.05)
        self.fail(message)

    def test_channels_coexist_and_repeat_launch_keeps_one_backend_each(self):
        self.assertEqual(self.owners(), {}, "use a private D-Bus session; do not activate existing applications")
        with tempfile.TemporaryDirectory(dir=ROOT / ".tmp") as temporary:
            directory = Path(temporary)
            children = []
            logs = []
            peer_pids = []
            try:
                for channel, application_id in IDS.items():
                    events = directory / f"{channel}.events"
                    peer_pid = directory / f"{channel}.peer-pid"
                    backend = directory / f"{channel}-backend"
                    backend.write_text(
                        f"#!/bin/sh\nexec {shlex.quote(shutil.which('python3') or '/usr/bin/python3')} "
                        f"{shlex.quote(str(ROOT / 'Tests/Linux/fixtures/linux_identity_backend.py'))} \"$@\"\n"
                    )
                    backend.chmod(0o755)
                    log = (directory / f"{channel}.log").open("w")
                    logs.append(log)
                    environment = dict(
                        os.environ,
                        HOME=str(directory),
                        XDG_CONFIG_HOME=str(directory / "config"),
                        DEVSPACE_BUILD_CHANNEL=channel,
                        DEVSPACE_BACKEND=str(backend),
                        DEVSPACE_TEST_EVENTS=str(events),
                        DEVSPACE_TEST_PEER_PID=str(peer_pid),
                        LD_LIBRARY_PATH=str(PREFIX / "lib"),
                        GDK_BACKEND="x11",
                    )
                    primary = subprocess.Popen([str(APP_PATHS[channel])], env=environment,
                                               stdout=log, stderr=log)
                    children.append(primary)
                    self.wait_for(lambda: self.owners().get(application_id) == primary.pid,
                                  primary, f"{channel} did not own its application identity")
                    self.wait_for(lambda: events.exists() and any(
                        json.loads(row)["kind"] == "handshake" for row in events.read_text().splitlines()
                    ), primary, f"{channel} backend did not complete its handshake")
                    peer_pids.append(int(peer_pid.read_text()))

                    secondary = subprocess.Popen([str(APP_PATHS[channel])], env=environment,
                                                 stdout=log, stderr=log)
                    children.append(secondary)
                    secondary.wait(timeout=10)
                    self.assertEqual(secondary.returncode, 0)
                    self.assertEqual(self.owners()[application_id], primary.pid)
                    requests = [json.loads(row) for row in events.read_text().splitlines()]
                    self.assertEqual(sum(row["kind"] == "handshake" for row in requests), 1,
                                     "repeat launch must not start a competing backend")
                self.assertEqual(self.owners(), {IDS[channel]: children[index * 2].pid
                                                for index, channel in enumerate(IDS)})
            finally:
                for child in reversed(children):
                    if child.poll() is None:
                        child.terminate()
                        try:
                            child.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            child.wait(timeout=5)
                for pid in peer_pids:
                    deadline = time.monotonic() + 5
                    while Path(f"/proc/{pid}").exists() and time.monotonic() < deadline:
                        time.sleep(0.05)
                    self.assertFalse(Path(f"/proc/{pid}").exists(), f"controlled backend {pid} was not reaped")
                for log in logs:
                    log.close()


if __name__ == "__main__":
    unittest.main()
