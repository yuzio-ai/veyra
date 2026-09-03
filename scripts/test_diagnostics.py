#!/usr/bin/env python3
"""Exercise the built app with isolated fake Codex processes and no account data."""
import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import sqlite3
import subprocess
import sys
import tempfile


SECRETS = ["private@example.invalid", "TEST_SECRET", "DATA_SECRET", "/private/account/path"]
SERVER = r'''
import json
import os
from pathlib import Path
import sys
import time

home = Path(os.environ["CODEX_HOME"])
mode = (home / "mode").read_text()
for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    with (home / "requests").open("a") as log:
        log.write(method + "\n")
    if method == "initialized":
        continue
    response = {"id": request["id"]}
    if method == "initialize":
        response["result"] = {}
    elif method == "account/read":
        response["result"] = {"account": {"type": "chatgpt", "email": "fixture@example.invalid"}}
    elif method == "account/rateLimits/read":
        if mode == "rpc_error":
            response["error"] = {
                "code": -32000,
                "message": "private@example.invalid TEST_SECRET /private/account/path",
                "data": {"credential": "DATA_SECRET"},
            }
            print("private@example.invalid TEST_SECRET DATA_SECRET /private/account/path", file=sys.stderr, flush=True)
        else:
            response["result"] = {"rateLimits": {"primary": {"usedPercent": 25, "windowDurationMins": 300}}}
    else:
        raise RuntimeError("Unexpected RPC method")
    broken_pipe = (mode == "pipe_initialize" and method == "initialize") or (mode == "pipe_account" and method == "account/read")
    if broken_pipe:
        os.close(0)
    if mode == "malformed":
        print("PRIVATE_RESPONSE not JSON", flush=True)
    else:
        print(json.dumps(response), flush=True)
    if broken_pipe:
        time.sleep(1)
        os._exit(0)
'''


def run_case(app, mode, expected_code, network=True):
    with tempfile.TemporaryDirectory(prefix="veyra-diagnostics-") as directory:
        home = Path(directory)
        with sqlite3.connect(home / "state_5.sqlite") as db:
            db.execute("CREATE TABLE threads (id TEXT, rollout_path TEXT)")
        (home / "mode").write_text(mode)
        server = home / "server.py"
        server.write_text(SERVER)
        executable = home / "fake-codex"
        if mode == "launch_failed":
            executable.write_text("#!/nonexistent/PRIVATE_INTERPRETER\n")
        else:
            executable.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(server))}\n")
        executable.chmod(0o755)
        environment = dict(os.environ, CODEX_HOME=str(home))
        # NSArgumentDomain overrides saved settings without persisting any preferences.
        command = [str(app), "--diagnose", "-codexHome", str(home), "-codexExecutable", str(executable)]
        if network:
            command.append("--network")
        # Python restores SIGPIPE to its default in the app, exposing missing descriptor protection.
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                              env=environment, restore_signals=True, start_new_session=True) as process:
            try:
                stdout, stderr = process.communicate(timeout=15)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate()
                raise AssertionError(f"{mode}: app did not finish within 15 seconds") from None
        assert process.returncode == 0, f"{mode}: app exited with {process.returncode}: {stderr}"
        for secret in SECRETS + [str(home), "PRIVATE_RESPONSE", "PRIVATE_INTERPRETER", "fixture@example.invalid"]:
            assert secret not in stdout + stderr, f"{mode}: private fixture data escaped diagnostics"
        payload = json.loads(stdout)
        assert "quotaErrorCode" in payload, f"{mode}: missing error code field"
        assert payload["quotaErrorCode"] == expected_code, f"{mode}: unexpected error category: {payload}"
        assert payload["tasks"] == [], f"{mode}: expected the isolated empty task database"
        if expected_code is None:
            assert payload["quotaError"] is None
            if network:
                assert payload["windows"][0]["remainingPercent"] == 75
            else:
                assert payload["windows"] == []
                assert not (home / "requests").exists(), "Local diagnostics started the quota sidecar"
        else:
            assert isinstance(payload["quotaError"], str) and payload["quotaError"]
        if mode != "launch_failed" and network:
            requests = (home / "requests").read_text().splitlines()
            assert requests[0] == "initialize"
            assert set(requests) <= {"initialize", "initialized", "account/read", "account/rateLimits/read"}
        print(f"PASS diagnostics: {mode} ({'network fixture' if network else 'local only'})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="Path to the built Veyra executable")
    app = parser.parse_args().app.resolve(strict=True)
    cases = [
        ("success", None),
        ("pipe_initialize", "disconnected"),
        ("pipe_account", "disconnected"),
        ("rpc_error", "rpc_failed"),
        ("malformed", "protocol_error"),
        ("launch_failed", "launch_failed"),
    ]
    for mode, expected_code in cases:
        run_case(app, mode, expected_code)
    run_case(app, "success", None, network=False)
    print(f"Passed {len(cases) + 1} isolated app diagnostics checks")


if __name__ == "__main__":
    main()
