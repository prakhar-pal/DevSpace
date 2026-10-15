#!/usr/bin/env python3
"""DevPod CLI double used only by backend integration tests."""
import json
import os
from pathlib import Path
import sys
import signal
import time
import subprocess

state_file = Path(os.environ["DEVSPACE_TEST_STATE"])
args = sys.argv[1:]
raw_logging = args[:2] == ["--log-output", "raw"]
if raw_logging:
    args = args[2:]

def slow_operation():
    if not state_file.with_name("slow").exists():
        return
    def stop(_signum, _frame):
        time.sleep(0.3)
        state_file.with_name("cleaned").write_text("done")
        sys.exit(1)
    signal.signal(signal.SIGTERM, stop)
    state_file.with_name("started").write_text(str(os.getpid()))
    time.sleep(30)

if args == ["list", "--output", "json", "--skip-pro"]:
    workspaces = [{"id": "pod", "provider": {"name": "test"}}]
    if state_file.with_name("extra-pod").exists():
        workspaces.append({"id": "other", "provider": {"name": "test"}})
    if state_file.with_name("created.json").exists():
        failure = state_file.with_name("post-create-list-fail")
        lag = state_file.with_name("creation-list-lag")
        if failure.exists() and int(failure.read_text()) > 0:
            failure.write_text(str(int(failure.read_text()) - 1))
            print("temporary workspace discovery failure", file=sys.stderr)
            sys.exit(1)
        if lag.exists() and int(lag.read_text()) > 0:
            lag.write_text(str(int(lag.read_text()) - 1))
        else:
            workspaces.append(json.loads(state_file.with_name("created.json").read_text()))
    print(json.dumps(workspaces))
elif args[0] == "status":
    observed = state_file.read_text() if state_file.exists() else "Running"
    if state_file.with_name("slow-status").exists():
        state_file.with_name("status-started").touch()
        time.sleep(0.6)
    print(json.dumps({"id": args[-1], "state": observed}))
elif args == ["stop", "--", "pod"]:
    state_file.write_text("Stopped")
elif args == ["up", "--ide", "none", "--", "pod"]:
    if state_file.with_name("slow").exists():
        def stop(_signum, _frame):
            time.sleep(0.3)
            state_file.with_name("cleaned").write_text("done")
            sys.exit(1)
        signal.signal(signal.SIGTERM, stop)
        state_file.with_name("signal-mask").write_text(str(signal.pthread_sigmask(signal.SIG_BLOCK, [])))
        state_file.with_name("started").write_text(str(os.getpid()))
        if state_file.with_name("read-stdin").exists():
            state_file.with_name("child-input").write_text(sys.stdin.read(1))
        if state_file.with_name("split-output").exists():
            os.write(1, b"Preparing \xce")
            time.sleep(0.1)
            print("Interleaved stderr", file=sys.stderr, flush=True)
            time.sleep(0.1)
            os.write(1, "λ界🙂\n".encode()[1:])
        elif state_file.with_name("large-output").exists():
            print("x" * 65536 + "\nPreparing λ界🙂", flush=True)
        else:
            print("Preparing λ界🙂" if raw_logging else "\x1b[0;1;36mPreparing λ界🙂\x1b[0m", flush=True)
        print("Checking provider", file=sys.stderr, flush=True)
        time.sleep(30)
    state_file.write_text("Running")
elif args[:3] == ["up", "--ide", "none"] and args[-1] == "https://example.invalid/new.git":
    slow_operation()
    workspace_id = args[args.index("--id") + 1] if "--id" in args else "generated-pod"
    state_file.with_name("created.json").write_text(json.dumps({"id": workspace_id, "provider": {"name": "test"}}))
elif args == ["up", "--recreate", "--ide", "none", "--", "pod"]:
    slow_operation()
    state_file.write_text("Running")
elif args[:2] == ["ssh", "--command"] and args[3:] == ["--start-services=false", "--", "pod"]:
    remote_home = state_file.with_name("remote-home")
    remote_home.mkdir(exist_ok=True)
    environment = dict(os.environ, HOME=str(remote_home), CLAUDE_CONFIG_DIR=str(remote_home / ".claude"))
    sys.exit(subprocess.call(["/bin/sh", "-c", args[2]], env=environment))
else:
    print(f"unexpected DevPod arguments: {args!r}", file=sys.stderr)
    sys.exit(1)
