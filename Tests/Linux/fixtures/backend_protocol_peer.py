#!/usr/bin/env python3
"""Small local protocol peer for the Swift frontend transport tests."""
import json
import sys
import time

mode = sys.argv[1]


def write_frame(value, fragmented=False):
    data = (json.dumps(value, separators=(",", ":")) + "\n").encode()
    if fragmented:
        for end in (1, 7, len(data) // 2, len(data)):
            start = 0 if end == 1 else previous
            sys.stdout.buffer.write(data[start:end])
            sys.stdout.buffer.flush()
            previous = end
            time.sleep(0.003)
    else:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()


for line in sys.stdin:
    request = json.loads(line)
    if request["kind"] != "handshake":
        continue

    if mode == "malformed":
        sys.stdout.write("{not-json}\n")
        sys.stdout.flush()
        break
    if mode == "oversized":
        sys.stdout.buffer.write(b"x" * (1_048_577) + b"\n")
        sys.stdout.buffer.flush()
        break

    channel = "production" if mode == "wrong-channel" else "development"
    write_frame({"version": 1, "id": request["id"], "kind": "ready", "payload": {
        "channel": channel,
        "application_id": "com.prakharp.devspace.dev" if channel == "development" else "com.prakharp.devspace",
        "protocol_version": "1",
    }}, fragmented=True)
    if mode == "disconnect":
        break
    if mode == "queue":
        time.sleep(30)
        break

    for command in sys.stdin:
        request = json.loads(command)
        kind = request["kind"]
        if kind == "poll":
            first = {"version": 1, "id": request["id"], "kind": "snapshot",
                     "payload": {"json": json.dumps({"revision": 5, "workspaces": []})}}
            second = {"version": 1, "kind": "platform_info", "payload": {"message": "Ready"}}
            sys.stdout.buffer.write((json.dumps(first) + "\n" + json.dumps(second) + "\n").encode())
            sys.stdout.buffer.flush()
        elif kind == "ping":
            write_frame({"version": 1, "id": request["id"], "kind": "pong"})
        elif kind == "shutdown":
            write_frame({"version": 1, "id": request["id"], "kind": "stopped"})
            break
    break
