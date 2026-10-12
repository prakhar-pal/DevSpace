#!/usr/bin/env python3
"""Transparent recorder for opt-in host acceptance; never fake backend events."""

import json
import os
from pathlib import Path
import subprocess
import selectors
import sys
import threading

log = Path(os.environ["DEVSPACE_TEST_EVENTS"])
trace = log.open("a")
lock = threading.Lock()
child = subprocess.Popen([os.environ["DEVSPACE_HOST_BACKEND"], *sys.argv[1:]],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE)


def record(direction, line):
    with lock:
        trace.write(json.dumps({"direction": direction, "frame": json.loads(line)}) + "\n")
        trace.flush()


def responses():
    for line in child.stdout:
        record("event", line)
        try:
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
        except BrokenPipeError:
            # GTK can close its reader before the backend's stopped event.
            # Keep draining/recording and prevent Python's exit flush failing.
            sink = os.open(os.devnull, os.O_WRONLY)
            try:
                os.dup2(sink, sys.stdout.fileno())
            finally:
                os.close(sink)


reader = threading.Thread(target=responses)
reader.start()
try:
    pending = b""
    with selectors.DefaultSelector() as selector:
        selector.register(sys.stdin, selectors.EVENT_READ)
        while child.poll() is None:
            if not selector.select(0.1):
                continue
            chunk = os.read(sys.stdin.fileno(), 65536)
            if not chunk:
                break
            pending += chunk
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                record("request", line)
            child.stdin.write(chunk)
            child.stdin.flush()
finally:
    child.stdin.close()
    child.wait(timeout=20)
    reader.join(timeout=5)
    trace.close()
sys.exit(child.returncode)
