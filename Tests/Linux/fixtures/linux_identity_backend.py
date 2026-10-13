#!/usr/bin/env python3
"""Minimal channel-aware backend peer for private GTK/D-Bus identity tests."""

import json
import os
import sys


def send(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


channel = "production"
if "--channel" in sys.argv:
    channel = sys.argv[sys.argv.index("--channel") + 1]
application_id = "com.prakharp.devspace.dev" if channel == "development" else "com.prakharp.devspace"
events_path = os.environ.get("DEVSPACE_TEST_EVENTS")
if pid_path := os.environ.get("DEVSPACE_TEST_PEER_PID"):
    with open(pid_path, "w", encoding="utf-8") as output:
        output.write(str(os.getpid()))

for line in sys.stdin:
    request = json.loads(line)
    if events_path:
        with open(events_path, "a", encoding="utf-8") as events:
            events.write(json.dumps(request) + "\n")
    kind = request["kind"]
    if kind == "handshake":
        send({"version": 1, "id": request["id"], "kind": "ready", "payload": {
            "channel": channel, "application_id": application_id, "protocol_version": "1",
        }})
    elif kind == "poll":
        snapshot = {
            "revision": 1, "workspaces": [], "selectedID": None,
            "layout": {"order": [], "hidden": [], "aliases": {}, "hidden_collapsed": False},
            "terminalPanes": [], "operations": [], "badges": [],
        }
        send({"version": 1, "id": request["id"], "kind": "snapshot",
              "payload": {"json": json.dumps(snapshot)}})
    elif kind == "shutdown":
        send({"version": 1, "id": request["id"], "kind": "stopped"})
        break
