#!/usr/bin/env python3
"""Protocol peer that supplies one running workspace and one controlled terminal."""

import json
import os
import sys

generation = "00000000-0000-0000-0000-000000000001"
pane = "00000000-0000-0000-0000-000000000002"
workspace = "fixture-pod"
events_path = os.environ.get("DEVSPACE_TEST_EVENTS")


def send(frame):
    sys.stdout.write(json.dumps(frame, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def snapshot(revision):
    value = {
        "revision": revision,
        "workspaces": [{"id": workspace, "provider": "docker", "source": "/tmp/project",
                        "lastUsed": "", "state": "Running", "error": None}],
        "selectedID": workspace,
        "layout": {"order": [], "hidden": [], "aliases": {}, "hidden_collapsed": False},
        "terminalPanes": [],
        "operations": [],
        "badges": [],
    }
    return {"version": 1, "kind": "snapshot", "payload": {"json": json.dumps(value)}}


for line in sys.stdin:
    request = json.loads(line)
    if events_path:
        with open(events_path, "a", encoding="utf-8") as events:
            events.write(json.dumps(request) + "\n")
    kind = request["kind"]
    if kind == "handshake":
        send({"version": 1, "id": request["id"], "kind": "ready", "payload": {
            "channel": "development", "application_id": "com.prakharp.devspace.dev",
            "protocol_version": "1",
        }})
    elif kind == "poll":
        frame = snapshot(1)
        frame["id"] = request["id"]
        send(frame)
        if sys.argv[1:] == ["crash"]:
            break
    elif kind == "connect":
        effect = {"kind": "terminal_launch", "workspaceID": workspace,
                  "generation": generation, "paneID": pane,
                  "executable": "/bin/sh", "arguments": [
                      "-c", "printf 'ready\\n'; IFS= read -r input; printf 'received:%s\\n' \"$input\"; exec sleep 30"],
                  "message": None}
        send({"version": 1, "kind": "terminal_launch", "payload": {"json": json.dumps(effect)}})
        send({"version": 1, "id": request["id"], "kind": "completed"})
    elif kind == "terminal_output":
        stale = "00000000-0000-0000-0000-000000000003"
        for effect in (
            {"kind": "terminal_inject", "workspaceID": workspace, "generation": stale,
             "paneID": pane, "executable": None, "arguments": [], "message": "stale-input\\n"},
            {"kind": "terminal_close", "workspaceID": workspace, "generation": stale,
             "paneID": pane, "executable": None, "arguments": [], "message": None},
            {"kind": "terminal_inject", "workspaceID": workspace, "generation": generation,
             "paneID": pane, "executable": None, "arguments": [], "message": "from-app\n"},
        ):
            send({"version": 1, "kind": effect["kind"], "payload": {"json": json.dumps(effect)}})
        frame = snapshot(2)
        frame["id"] = request["id"]
        frame["payload"]["json"] = json.dumps({
            **json.loads(frame["payload"]["json"]),
            "terminalPanes": [{"id": pane, "workspaceID": workspace}],
        })
        send(frame)
    elif kind == "terminal_exit":
        frame = snapshot(3)
        frame["id"] = request["id"]
        send(frame)
    elif kind == "shutdown":
        send({"version": 1, "id": request["id"], "kind": "stopped"})
        break
