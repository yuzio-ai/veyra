#!/usr/bin/env python3
"""Exercise the built app with isolated fake Codex processes and no account data."""
import argparse
import json
import os
import plistlib
from pathlib import Path
import shlex
import signal
import sqlite3
import subprocess
import sys
import tempfile
import uuid


SECRETS = ["private@example.invalid", "TEST_SECRET", "DATA_SECRET", "/private/account/path",
           "PRIVATE_TASK_TITLE", "PRIVATE_PROGRESS", "PRIVATE_AGENT_PATH", "PRIVATE_AGENT_ROLE"]
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
        (home / "client-version").write_text(request["params"]["clientInfo"]["version"])
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


def run_case(app, mode, expected_code, network=True, with_task=False, benchmark=False):
    with tempfile.TemporaryDirectory(prefix="veyra-diagnostics-") as directory:
        home = Path(directory)
        with sqlite3.connect(home / "state_5.sqlite") as db:
            db.execute("CREATE TABLE threads (id TEXT, rollout_path TEXT, title TEXT, source TEXT, updated_at INTEGER, archived INTEGER)")
            if with_task:
                rollout = home / "child.jsonl"
                source = {"subagent": {"thread_spawn": {"parent_thread_id": "fixture-parent",
                          "agent_path": "/root/PRIVATE_AGENT_PATH", "agent_role": "PRIVATE_AGENT_ROLE"}}}
                db.execute("INSERT INTO threads VALUES (?, ?, ?, ?, strftime('%s','now'), 0)",
                           ("fixture-child", str(rollout), "", json.dumps(source)))
                db.execute("INSERT INTO threads VALUES (?, ?, ?, ?, 0, 1)",
                           ("fixture-parent", str(home / "missing-parent.jsonl"), "PRIVATE_TASK_TITLE", "cli"))
                events = [
                    {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "fixture-turn"}},
                    {"type": "turn_context", "payload": {"model": "fixture-model"}},
                    {"type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"total_tokens": 123}}}},
                    {"type": "response_item", "payload": {"type": "message", "role": "assistant", "phase": "commentary",
                        "content": [{"type": "output_text", "text": "PRIVATE_PROGRESS"}],
                        "internal_chat_message_metadata_passthrough": {"turn_id": "fixture-turn"}}},
                ]
                rollout.write_text("".join(json.dumps(event) + "\n" for event in events))
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
        if benchmark:
            command.append("--energy-benchmark")
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
        assert payload['energyBenchmarkIsolation'] is benchmark, f"{mode}: unexpected benchmark isolation capability"
        assert "quotaErrorCode" in payload, f"{mode}: missing error code field"
        assert payload["quotaErrorCode"] == expected_code, f"{mode}: unexpected error category: {payload}"
        if with_task:
            assert len(payload["tasks"]) == 1, "Expected the child without its archived parent in diagnostic task counts"
            assert payload["tasks"][0]["id"] == "fixture-child"
            assert payload["tasks"][0]["totalTokens"] == 123
        else:
            assert payload["tasks"] == [], f"{mode}: expected the isolated empty task database"
        if expected_code is None:
            assert payload["quotaError"] is None
            if network:
                assert payload["windows"][0]["remainingPercent"] == 75
            else:
                assert payload["windows"] == []
                assert payload["quotaSource"] is None
                assert not (home / "requests").exists(), "Local diagnostics started the quota sidecar"
        else:
            assert isinstance(payload["quotaError"], str) and payload["quotaError"]
        if mode != "launch_failed" and network:
            requests = (home / "requests").read_text().splitlines()
            assert requests[0] == "initialize"
            with (app.parent.parent / "Info.plist").open("rb") as info:
                expected_version = plistlib.load(info)["CFBundleShortVersionString"]
            assert (home / "client-version").read_text() == expected_version, "Handshake version differs from app bundle"
            assert set(requests) <= {"initialize", "initialized", "account/read", "account/rateLimits/read"}
        print(f"PASS diagnostics: {mode} ({'task context privacy' if with_task else 'network fixture' if network else 'local only'})")


def run_language_cases(app):
    # Launch arguments override language preferences for this process only.
    cases = [
        ('(en)', 'en_US', 'Diagnostics failed: unable to complete local diagnostics.'),
        ('("zh-Hans")', 'zh_CN', '诊断失败：无法完成本机诊断。'),
        ('("fr-FR")', 'fr_FR', 'Diagnostics failed: unable to complete local diagnostics.'),
        ('("fr-FR", "zh-Hans")', 'fr_FR', '诊断失败：无法完成本机诊断。'),
        ('(en)', 'zh_CN', 'Diagnostics failed: unable to complete local diagnostics.'),
    ]
    with tempfile.TemporaryDirectory(prefix="veyra-language-") as home:
        for languages, locale, expected in cases:
            result = subprocess.run([
                str(app), "--diagnose", "-codexHome", home,
                "-AppleLanguages", languages, "-AppleLocale", locale,
            ], capture_output=True, text=True, timeout=15)
            assert result.returncode == 0, result.stderr
            assert result.stdout.strip() == expected, (languages, locale, result.stdout)
            print(f"PASS language: {languages}, region: {locale}")
    return len(cases)


def run_revoked_native_lease_cases(app):
    for mode in ('menu', 'layouts'):
        for contents in (None, 'wrong-token'):
            with tempfile.TemporaryDirectory(prefix='veyra-preview-lease-') as name:
                directory = Path(name)
                token = str(uuid.uuid4())
                if contents is not None:
                    (directory / 'active-lease').write_text(contents)
                arguments = (['--preview-menu', 'multiple', '--show-menu', '--exit-after-menu-checks',
                              '--exercise-menu-to', str(directory)] if mode == 'menu'
                             else ['--render-previews', str(directory)])
                result = subprocess.run([str(app)] + arguments + ['--preview-lease', token],
                    capture_output=True, text=True, timeout=10, start_new_session=True)
                assert result.returncode == 1, 'A revoked GUI fixture must exit before initializing the app'
                assert result.stderr.strip() == 'GUI preview fixture lease is unavailable.'
                receipt = json.loads((directory / 'process.json').read_text())
                assert receipt['pid'] == receipt['group'] and receipt['token'] == token
                assert not (directory / 'menu-check.json').exists()
                assert not (directory / 'layouts.json').exists()
    print('PASS diagnostics: revoked and replaced GUI launch leases')
    return 4


def run_unsupported_command_cases(app):
    removed_commands = [
        '--provider-credential', '--provider-credential-fixture', '--create-credential-fixture',
        '--create-denied-credential-fixture', '--delete-credential-fixture', '--lock-credential-fixture',
        '--create-model-catalog-fixture', '--render-provider-previews', '--unknown-command', '--preview-dsh-only',
    ]
    commands = [[command, 'PRIVATE_VALUE'] for command in removed_commands] + [
        *[['--preview-menu', scenario] for scenario in ('dsh-only', 'dsh-idle', 'dsh-unknown', 'dsh-error')],
        ['--render-previews', 'PRIVATE_VALUE', '--preview-dsh-only'],
        ['--preview-menu', 'custom-model'], ['--preview-menu', 'PRIVATE_VALUE'],
        ['--preview-menu', 'single', '--preview-appearance', 'PRIVATE_VALUE'],
        ['--preview-menu', 'single', '--preview-menu', 'multiple'], ['--preview-settings-only'],
        ['--exercise-menu-to', 'PRIVATE_VALUE'],
        ['--render-previews', 'PRIVATE_VALUE', '--preview-menu', 'single'],
    ]
    with tempfile.TemporaryDirectory(prefix='veyra-unsupported-command-') as home:
        for arguments in commands:
            # Keep a future validation regression isolated even if it reaches app startup.
            isolated = ['--energy-benchmark', '-codexHome', home, '-codexExecutable', '/usr/bin/true']
            result = subprocess.run([str(app)] + arguments + isolated,
                env=dict(os.environ, CODEX_HOME=home), capture_output=True, text=True, timeout=5)
            assert result.returncode == 64, 'Unsupported command must exit before starting the application'
            assert result.stdout == '', 'Unsupported command must not write credential output'
            assert result.stderr == 'Veyra: unsupported or incomplete command-line arguments.\n'
            assert not list(Path(home).iterdir()), 'Unsupported command must not create runtime data'
    print('PASS diagnostics: removed and unsupported commands fail before app startup')
    return len(commands)


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
    run_case(app, "success", None, network=False, with_task=True)
    run_case(app, "success", None, network=False, with_task=True, benchmark=True)
    language_checks = run_language_cases(app)
    lease_checks = run_revoked_native_lease_cases(app)
    argument_checks = run_unsupported_command_cases(app)
    print(f"Passed {len(cases) + 3 + lease_checks + argument_checks} isolated app diagnostics checks and {language_checks} language checks")


if __name__ == "__main__":
    main()
