#!/usr/bin/env python3
"""Measure an isolated Veyra Release process with fixture data, never a real account.

CPU time is measured with libproc; wait4 reports lifetime CPU including reaped children.
This is a CPU/resource benchmark, not a watts or battery-life measurement.
"""
import argparse
from contextlib import ExitStack, contextmanager
import ctypes
import datetime
import json
import os
from pathlib import Path
import selectors
import signal
import sqlite3
import subprocess
import tempfile
import time
import uuid


class RUsage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_ubyte * 16)] + [(name, ctypes.c_uint64) for name in
        ['user', 'system', 'package_idle_wakeups', 'interrupt_wakeups', 'pageins',
         'wired_size', 'resident_size', 'physical_footprint', 'start_time', 'exit_time']]


class MachTimebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]


def timebase():
    result = MachTimebase()
    if ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(ctypes.byref(result)) != 0:
        raise RuntimeError('Cannot read the Mach timebase')
    return result


def usage(pid):
    result = RUsage()
    lib = ctypes.CDLL('/usr/lib/libproc.dylib')
    if lib.proc_pid_rusage(pid, 0, ctypes.byref(result)) != 0:
        raise RuntimeError('Cannot sample benchmark process')
    return result


def event(kind, payload, now):
    return json.dumps({'type': kind, 'timestamp': datetime.datetime.fromtimestamp(now, datetime.timezone.utc).isoformat().replace('+00:00', 'Z'), 'payload': payload}) + '\n'


@contextmanager
def handle_termination():
    def terminate(signum, frame):
        raise SystemExit(128 + signum)
    previous = signal.signal(signal.SIGTERM, terminate)
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM, previous)


def wait_for_ready(process, timeout=5):
    deadline = time.monotonic() + timeout
    received = b''
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        while b'\n' not in received and len(received) < 6:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise RuntimeError('Fixture lock holder readiness timed out')
            chunk = os.read(process.stdout.fileno(), 6 - len(received))
            if not chunk:
                break
            received += chunk
    if received != b'READY\n':
        raise RuntimeError('Fixture lock holder failed to start')
    process.stdout.close()


def stop_process(process, collect_usage=False, timeout=5):
    """Reap a fixture even when startup, preflight or measurement is interrupted."""
    try:
        if process.returncode is not None:
            if collect_usage:
                raise RuntimeError('Measurement process was already reaped; CPU statistics unavailable')
            return
        for stop_signal in (signal.SIGTERM, signal.SIGKILL):
            try:
                if collect_usage:
                    # Popen.terminate() polls/reaps first, losing wait4's resource data.
                    os.kill(process.pid, stop_signal)
                elif stop_signal == signal.SIGTERM:
                    process.terminate()
                else:
                    process.kill()
            except ProcessLookupError:
                pass
            if collect_usage:
                deadline = time.monotonic() + timeout
                while True:
                    pid, status, resources = os.wait4(process.pid, os.WNOHANG)
                    if pid:
                        process.returncode = os.waitstatus_to_exitcode(status)
                        return resources
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    time.sleep(min(0.05, remaining))
            else:
                try:
                    process.wait(timeout=timeout)
                    return
                except subprocess.TimeoutExpired:
                    pass
        raise RuntimeError('Unable to reap benchmark process after SIGKILL')
    finally:
        if process.stdout is not None:
            process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--scenario', choices=['idle', 'active', 'panel'], required=True)
    parser.add_argument('--seconds', type=int, default=300)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if args.seconds <= 0:
        parser.error('--seconds must be positive')
    app = args.app.resolve(strict=True)
    # Use the checkout's real path: older Veyra builds cannot match lsof's
    # /private/var aliases to Foundation's normalized temporary-directory URLs.
    fixture_parent = Path(__file__).resolve().parent.parent / 'build'
    fixture_parent.mkdir(exist_ok=True)
    with handle_termination(), tempfile.TemporaryDirectory(prefix='energy-fixture-', dir=fixture_parent) as temporary, ExitStack() as cleanup:
        root = Path(temporary)
        home = root / 'home'; home.mkdir()
        # Forward toolchain/session basics, never account variables or real session data.
        names = ('PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL', 'TZ', 'DEVELOPER_DIR')
        environment = {name: os.environ[name] for name in names if name in os.environ}
        environment.update(CODEX_HOME=str(home))
        locks = home / 'thread-writer-locks'; locks.mkdir()
        sessions = home / 'sessions'; sessions.mkdir()
        helper = root / 'codex'
        subprocess.run(['xcrun', 'clang', '-O2', str(Path(__file__).with_name('energy_fixture.c')), '-o', str(helper)], check=True, capture_output=True, timeout=60)
        state = sqlite3.connect(home / 'state_5.sqlite')
        cleanup.callback(state.close)
        state.executescript('PRAGMA journal_mode=WAL; CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT, source TEXT, model TEXT, updated_at INTEGER, archived INTEGER, tokens_used INTEGER); CREATE INDEX updated ON threads(updated_at)')
        history = sqlite3.connect(home / 'thread_history_1.sqlite')
        cleanup.callback(history.close)
        history.executescript('PRAGMA journal_mode=WAL; CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,rollout_ordinal INTEGER,status TEXT,started_at INTEGER,completed_at INTEGER); CREATE UNIQUE INDEX idx_thread_turns_page ON thread_turns(thread_id,rollout_ordinal)')
        now = int(time.time())
        active = []
        for i in range(1000):
            ident = str(uuid.UUID(int=i + 1))
            running = args.scenario != 'idle' and i < 3
            log = sessions / (ident + '.jsonl')
            text = event('turn_context', {'model': 'fixture-model'}, now)
            text += event('event_msg', {'type': 'task_started', 'turn_id': 'turn'}, now)
            text += event('event_msg', {'type': 'token_count', 'info': {'total_token_usage': {'total_tokens': 100}}, 'rate_limits': {'limit_id': 'codex', 'primary': {'used_percent': 25, 'window_minutes': 300, 'resets_at': now + 18000}}}, now)
            if not running: text += event('event_msg', {'type': 'task_complete', 'turn_id': 'turn'}, now)
            log.write_text(text)
            state.execute('INSERT INTO threads VALUES(?,?,?,?,?,?,0,100)', (ident, str(log), 'Energy fixture', 'cli', 'fixture-model', now - i))
            history.execute('INSERT INTO thread_turns VALUES(?,?,1,?,?,?)', (ident, 'turn', 'inProgress' if running else 'completed', now, None if running else now))
            if running:
                lock = locks / (ident + '.lock'); lock.touch(); active.append((ident, log, lock))
        state.commit(); history.commit()
        holder = subprocess.Popen([str(helper), 'hold'] + [str(x[2]) for x in active], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) if active else None
        if holder:
            cleanup.callback(stop_process, holder)
            wait_for_ready(holder)
        # Launch arguments override saved manual paths; environment alone does not.
        command = [str(app), '--energy-benchmark', '-codexHome', str(home), '-codexExecutable', str(helper)]
        # Check that the actual target app recognizes the intended process/task state.
        probe = subprocess.run(command + ['--diagnose'], env=environment,
                               capture_output=True, text=True, timeout=20, check=True)
        diagnostic = json.loads(probe.stdout)
        if diagnostic.get('energyBenchmarkIsolation') is not True:
            raise RuntimeError('This app does not support isolated energy benchmarks; rebuild the current source')
        confirmed = sum(task['activity'] == 'running' for task in diagnostic['tasks'])
        if confirmed != len(active):
            probe_files = subprocess.run(['/usr/sbin/lsof', '-nP', '-Fpcn', '-p', str(holder.pid)], capture_output=True, text=True, timeout=10) if holder else None
            own_files = [line.replace(str(home), 'FIXTURE_HOME').replace(str(home.resolve()), 'FIXTURE_HOME')
                         for line in (probe_files.stdout.splitlines() if probe_files else [])
                         if line.startswith('c') or '/thread-writer-locks/' in line]
            raise RuntimeError(f'Fixture task detection failed: expected {len(active)}, got {confirmed}; '
                               f'activities={[task["activity"] for task in diagnostic["tasks"]]}; '
                               f'warning={diagnostic.get("taskWarning")}; holder={own_files}')
        (home / 'quota-requests').unlink(missing_ok=True)
        # This is a native NSWindow with the same panel content; report it distinctly.
        if args.scenario == 'panel': command += ['--show-panel']
        process = subprocess.Popen(command, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cleanup.callback(stop_process, process)
        samples = []
        result = None
        try:
            time.sleep(10)  # Exclude launch/warm-up from the main-process comparison.
            if process.poll() is not None:
                raise RuntimeError('Measurement process exited during warm-up')
            before = usage(process.pid)
            start = time.monotonic()
            end = start + args.seconds
            while time.monotonic() < end:
                time.sleep(min(5, max(0, end - time.monotonic())))
                now = time.time()
                for ident, log, _ in active:
                    with log.open('a') as output:
                        output.write(event('event_msg', {'type': 'token_count', 'info': {'total_token_usage': {'total_tokens': int(now)}}, 'rate_limits': {'limit_id': 'codex', 'primary': {'used_percent': 25, 'window_minutes': 300, 'resets_at': int(now) + 18000}}}, now))
                    state.execute('UPDATE threads SET updated_at=?,tokens_used=? WHERE id=?', (int(now), int(now), ident))
                if active: state.commit()
                if process.poll() is not None:
                    raise RuntimeError('Measurement process exited during sampling')
                sample = usage(process.pid)
                samples.append(sample.resident_size)
            if process.poll() is not None:
                raise RuntimeError('Measurement process exited before the final sample')
            after = usage(process.pid)
            elapsed = time.monotonic() - start
            cpu_ticks = after.user + after.system - before.user - before.system
            tb = timebase()
            cpu = cpu_ticks * tb.numer / tb.denom / 1e9
            result = {'scenario': args.scenario, 'panel_kind': 'native_debug_window' if args.scenario == 'panel' else None,
                      'app': str(app), 'duration_seconds': elapsed, 'warmup_seconds': 10,
                      'fixture_threads': 1000, 'fixture_active_tasks': len(active),
                      'verified_running_tasks': confirmed,
                      'isolation': {'codex_fixture': True,
                                    'updates_disabled': True, 'global_shortcut_disabled': True},
                      'main_cpu_mach_ticks': cpu_ticks, 'mach_timebase_numer': tb.numer, 'mach_timebase_denom': tb.denom,
                      'main_cpu_seconds': cpu, 'main_average_cpu_percent': cpu / elapsed * 100,
                      'main_peak_resident_bytes': max(samples),
                      'package_idle_wakeups': after.package_idle_wakeups - before.package_idle_wakeups,
                      'interrupt_wakeups': after.interrupt_wakeups - before.interrupt_wakeups,
                      'quota_requests': len((home / 'quota-requests').read_text().splitlines()) if (home / 'quota-requests').exists() else 0}
        finally:
            resources = stop_process(process, collect_usage=True) if process.returncode is None else None
        if result is not None:
            result['lifetime_cpu_seconds_including_reaped_children'] = resources.ru_utime + resources.ru_stime
            result['lifetime_peak_resident_bytes'] = resources.ru_maxrss
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(result, indent=2) + '\n')
            print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
