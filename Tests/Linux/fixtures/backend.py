#!/usr/bin/env python3
"""Controlled subprocess peer for GTK transport tests; no DevPod access."""
import json
import os
import sys
from pathlib import Path

state = "Running"
poll_count = 0
connect_count = 0
reconnect_count = 0
hidden_ids = []
hidden_collapsed = False
aliases = {}
operation_cancelled = False
selected_id = None
for line in sys.stdin:
    request = json.loads(line)
    if events_path := os.environ.get("DEVSPACE_TEST_EVENTS"):
        with open(events_path, "a", encoding="utf-8") as events:
            events.write(json.dumps(request) + "\n")
    kind = request["kind"]
    if kind == "handshake":
        response = {"version": 1, "id": request["id"], "kind": "ready"}
        if len(sys.argv) > 2 and sys.argv[2] == "notification-listener-unavailable":
            response["payload"] = {"notify_error": "listener port is already in use"}
    elif kind == "poll":
        poll_count += 1
        if len(sys.argv) > 2 and sys.argv[2] == "periodic-status" and poll_count > 1:
            state = "Stopped"
        if len(sys.argv) > 2 and sys.argv[2] == "terminal-error" and poll_count > 1:
            state = "Refreshed"
        snapshot = {"revision": 1, "workspaces": [{"id": "pod", "state": state}]}
        if len(sys.argv) > 2 and sys.argv[2] == "platform-zed" and poll_count == 1:
            print(json.dumps({"version": 1, "kind": "platform_open_zed", "payload": {
                "workspace_id": "pod", "url": "ssh://pod.devpod/workspace/a%20b/%CE%B1"}}), flush=True)
        if len(sys.argv) > 2 and sys.argv[2] in ("queued-selection", "queued-stopped"):
            snapshot["workspaces"][0]["state"] = "Selected" if selected_id == "pod" else (
                "Stopped" if sys.argv[2] == "queued-stopped" else "Running")
        if len(sys.argv) > 2 and sys.argv[2] == "platform-notification":
            snapshot["badges"] = ["pod"]
            if poll_count == 1:
                print(json.dumps({"version": 1, "kind": "platform_notify", "payload": {
                    "workspace_id": "pod", "title": "Work α", "message": "Claude finished"}}), flush=True)
        if len(sys.argv) > 2 and sys.argv[2] == "notification-badge":
            snapshot["badges"] = [] if selected_id == "pod" else ["pod"]
            snapshot["selectedID"] = selected_id
        if len(sys.argv) > 2 and sys.argv[2] == "operation-progress" and not operation_cancelled:
            snapshot["operations"] = [{"id": "operation-42", "kind": "start", "workspaceID": "pod",
                "state": "running", "output": "Preparing λ界🙂\nChecking provider\n"}]
        if len(sys.argv) > 2 and sys.argv[2] == "stable-sidebar":
            snapshot["operations"] = [{"id": "operation-42", "kind": "start", "workspaceID": "pod",
                "state": "running", "output": f"Progress {poll_count}"}]
        if len(sys.argv) > 2 and sys.argv[2] == "sidebar-layout":
            snapshot["workspaces"] += [{"id": "alpha", "state": "Running"}, {"id": "beta", "state": "Stopped"}]
            snapshot["layout"] = {"order": ["beta", "pod", "alpha"], "hidden": ["alpha"],
                                  "aliases": {"beta": "Other pod", "pod": "Work pod"}, "hidden_collapsed": True}
        if len(sys.argv) > 2 and sys.argv[2] == "sidebar-selected-hidden":
            snapshot["workspaces"] += [{"id": "other", "state": "Running"}]
            snapshot["selectedID"] = "pod"
            snapshot["layout"] = {"hidden": ["pod", "other"], "hidden_collapsed": True}
        if len(sys.argv) > 2 and sys.argv[2] == "sidebar-editing":
            snapshot["layout"] = {"hidden": hidden_ids, "hidden_collapsed": hidden_collapsed, "aliases": aliases}
        response = {"version": 1, "id": request["id"], "kind": "snapshot",
                    "payload": {"json": json.dumps(snapshot)}}
    elif kind == "shutdown":
        if len(sys.argv) > 2 and Path(sys.argv[2]).is_absolute():
            Path(sys.argv[2]).write_text("shutdown")
        break
    elif kind == "connect":
        connect_count += 1
        effect = {"kind": "terminal_launch", "workspaceID": "pod",
                  "generation": "00000000-0000-0000-0000-000000000001",
                  "paneID": "00000000-0000-0000-0000-000000000002",
                  "executable": "/bin/sh", "arguments": ["-c", "printf '\\033]7;file://localhost/tmp/backend-cwd\\007'; sleep 3"]}
        if connect_count > 1:
            effect["arguments"] = ["-c", "printf '\\033]7;file://localhost/tmp/backend-cwd\\007'; sleep 60"]
        response = {"version": 1, "kind": "terminal_launch", "payload": {"json": json.dumps(effect)}}
        if len(sys.argv) > 2 and sys.argv[2] == "terminal-error":
            effect = {"kind": "terminal_error", "workspaceID": "pod",
                      "generation": "00000000-0000-0000-0000-000000000001",
                      "arguments": [], "message": "SSH authentication failed"}
            response = {"version": 1, "kind": "terminal_error", "payload": {"json": json.dumps(effect)}}
    elif kind == "reconnect":
        reconnect_count += 1
        effect = {"kind": "terminal_close", "workspaceID": "pod",
                  "generation": "00000000-0000-0000-0000-000000000001",
                  "paneID": "00000000-0000-0000-0000-000000000002", "arguments": []}
        if reconnect_count == 1:
            effect["generation"] = "00000000-0000-0000-0000-000000000009"
            print(json.dumps({"version": 1, "kind": "terminal_close", "payload": {"json": json.dumps(effect)}}), flush=True)
            # This ordered snapshot proves GTK consumed the stale close frame
            # before the test asserts that the current pane is still present.
            state = "StaleFrameSeen"
            snapshot = {"revision": 2, "workspaces": [{"id": "pod", "state": state}]}
            response = {"version": 1, "kind": "snapshot", "payload": {"json": json.dumps(snapshot)}}
        else:
            state = "Running"
            response = {"version": 1, "kind": "terminal_close", "payload": {"json": json.dumps(effect)}}
    elif kind == "paste_image":
        payload = request["payload"]
        image = Path(payload["source_path"])
        if image.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
            raise ValueError("clipboard image was not encoded as PNG")
        image.unlink()
        response = {"version": 1, "kind": "terminal_inject", "payload": {"json": json.dumps({
            "kind": "terminal_inject", "workspaceID": payload["workspace_id"],
            "generation": payload["generation"], "paneID": payload["pane_id"],
            "message": "Image pasted: /tmp/fixture.png "})}}
    else:
        if kind == "select":
            selected_id = request["payload"]["workspace_id"]
        if kind == "create":
            if request["payload"] != {"repository": "https://example.invalid/α repo.git", "workspace_id": "new-pod"}:
                raise ValueError("creation arguments were not preserved")
            state = "Created"
        elif kind == "recreate":
            if request["payload"]["workspace_id"] != "pod":
                raise ValueError("wrong workspace recreated")
            state = "Recreated"
        elif kind == "delete":
            state = "Deleted"
        if kind == "cancel":
            if request["payload"].get("request_id") != "operation-42":
                raise ValueError("cancel requires operation request identity, not workspace identity")
            operation_cancelled = True
            state = "Cancelled"
        if kind == "hide":
            hidden_ids = [request["payload"]["workspace_id"]]
        elif kind == "show":
            hidden_ids = []
        elif kind == "collapse_hidden":
            hidden_collapsed = True
        elif kind == "expand_hidden":
            hidden_collapsed = False
        elif kind == "alias":
            aliases[request["payload"]["workspace_id"]] = request["payload"]["name"]
        if kind == "stop" and request["payload"]["workspace_id"] == "pod":
            state = "Stopped"
        response = {"version": 1, "id": request["id"], "kind": "completed"}
    print(json.dumps(response), flush=True)
    if kind == "poll" and len(sys.argv) > 2 and sys.argv[2] == "exit":
        break
