#!/usr/bin/env python3
"""Exercise benchmark launch isolation with temporary fixtures and fake processes."""
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('measure_energy', Path(__file__).with_name('measure_energy.py'))
energy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(energy)


PROCESS_RUNNER = r'''
import functools, importlib.util, json, os, signal, subprocess, sys, time
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
source, directory, mode = sys.argv[1:]
spec = importlib.util.spec_from_file_location('energy', source)
energy = importlib.util.module_from_spec(spec); spec.loader.exec_module(energy)
root = Path(directory); app = root / 'Veyra'; app.touch()
output = root / 'result.json'
if mode == 'output-failure': output.mkdir()
real_popen, real_sleep = subprocess.Popen, time.sleep
stop = functools.partial(energy.stop_process, timeout=0.15)
ready = functools.partial(energy.wait_for_ready, timeout=0.15)
def run(command, **kwargs):
    if command[0] == 'xcrun':
        if mode == 'compile-timeout': raise subprocess.TimeoutExpired(command, 60)
        return SimpleNamespace(stdout='')
    if mode == 'preflight-failure': raise RuntimeError('Fixture preflight failed')
    return SimpleNamespace(stdout=json.dumps({'energyBenchmarkIsolation': True,
        'tasks': [{'activity': 'running'}] * 3}))
def popen(command, **kwargs):
    holder = command[1] == 'hold'
    if not holder and mode == 'launch-failure': raise OSError('Fixture launch failed')
    body = 'import signal,time,sys; '
    if not holder: body += 'signal.signal(signal.SIGTERM,signal.SIG_IGN); '
    if holder:
        body += 'sys.stdout.write("R"); sys.stdout.flush(); ' if mode == 'readiness-timeout' else 'print("READY",flush=True); '
    if not holder and mode == 'early-exit': body += 'raise SystemExit(2)'
    else: body += 'time.sleep(30)'
    child = real_popen([sys.executable, '-I', '-B', '-c', body],
        stdout=subprocess.PIPE if holder else subprocess.DEVNULL, env=kwargs.get('env'))
    print('FIXTURE_PID ' + str(child.pid), flush=True)
    # Let the measured worker install its SIGTERM handler (or exit).
    if not holder: real_sleep(0.1)
    return child
def sample(pid):
    if mode == 'interrupt': os.kill(os.getpid(), signal.SIGINT)
    if mode == 'terminate': os.kill(os.getpid(), signal.SIGTERM)
    if mode == 'sampling-failure': raise RuntimeError('Fixture sampling failed')
    return energy.RUsage()
with patch.object(energy, '__file__', str(root / 'scripts/measure_energy.py')), \
     patch('sys.argv', ['energy', '--app', str(app), '--scenario', 'active',
                       '--seconds', '1', '--output', str(output)]), \
     patch.object(energy.subprocess, 'run', side_effect=run), \
     patch.object(energy.subprocess, 'Popen', side_effect=popen), \
     patch.object(energy.time, 'sleep', side_effect=lambda seconds: real_sleep(min(seconds, 0.01))), \
     patch.object(energy, 'usage', side_effect=sample), \
     patch.object(energy, 'timebase', return_value=energy.MachTimebase(1, 1)), \
     patch.object(energy, 'stop_process', side_effect=stop), \
     patch.object(energy, 'wait_for_ready', side_effect=ready):
    energy.main()
'''


class EnergyProcessLifecycleTests(unittest.TestCase):
    def testMainWithRealProcessesAcrossLifecycle(self):
        modes = ('complete', 'compile-timeout', 'readiness-timeout', 'preflight-failure',
                 'launch-failure', 'sampling-failure', 'early-exit', 'interrupt', 'terminate', 'output-failure')
        for mode in modes:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix='veyra-energy-process-') as directory:
                root = Path(directory).resolve()
                runner = subprocess.Popen([sys.executable, '-I', '-B', '-c', PROCESS_RUNNER,
                    str(Path(energy.__file__).resolve()), str(root), mode],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                stdout = ''
                try:
                    try:
                        stdout, stderr = runner.communicate(timeout=10)
                    except subprocess.TimeoutExpired as error:
                        stdout = error.output or ''
                        if isinstance(stdout, bytes): stdout = stdout.decode()
                        self.fail(f'{mode}: benchmark failed to exit within 10 seconds')
                    if mode == 'complete':
                        self.assertEqual(runner.returncode, 0, stderr)
                        result = json.loads((root / 'result.json').read_text())
                        self.assertEqual(result['verified_running_tasks'], 3)
                        self.assertGreater(result['lifetime_cpu_seconds_including_reaped_children'], 0)
                    else:
                        self.assertNotEqual(runner.returncode, 0)
                        self.assertFalse((root / 'result.json').is_file())
                        errors = {'compile-timeout': 'TimeoutExpired', 'readiness-timeout': 'readiness timed out',
                                  'preflight-failure': 'Fixture preflight failed', 'launch-failure': 'Fixture launch failed',
                                  'sampling-failure': 'Fixture sampling failed', 'early-exit': 'exited during warm-up',
                                  'interrupt': 'KeyboardInterrupt', 'output-failure': 'IsADirectoryError'}
                        if mode == 'terminate': self.assertEqual(runner.returncode, 128 + signal.SIGTERM)
                        else: self.assertIn(errors[mode], stderr)
                    pids = list(map(int, re.findall(r'^FIXTURE_PID (\d+)$', stdout, re.MULTILINE)))
                    expected_children = 0 if mode == 'compile-timeout' else 1 if mode in ('readiness-timeout', 'preflight-failure', 'launch-failure') else 2
                    self.assertEqual(len(pids), expected_children)
                    for pid in pids:
                        with self.assertRaises(ProcessLookupError, msg=f'{mode}: unreaped child {pid}'):
                            os.kill(pid, 0)
                    self.assertEqual(list((root / 'build').iterdir()), [])
                finally:
                    # Keep a failed regression from leaving its own workers behind.
                    for pid in map(int, re.findall(r'^FIXTURE_PID (\d+)$', stdout, re.MULTILINE)):
                        try: os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError: pass
                    if runner.poll() is None: runner.kill()
                    runner.communicate(timeout=5)


class EnergyIsolationTests(unittest.TestCase):
    def exercise(self, scenario, supported=True, failure=None):
        with tempfile.TemporaryDirectory(prefix='veyra-energy-test-') as directory:
            root = Path(directory).resolve()
            app = root / 'Veyra'
            app.touch()
            output = root / 'result.json'
            holder = Mock(pid=41, returncode=None, stdout=io.BytesIO(b'BAD\n' if failure == 'readiness' else b'READY\n'))
            process = Mock(pid=42, returncode=None, stdout=None)
            process.poll.return_value = None
            launches = []

            def check_launch(command, environment):
                self.assertIn('--energy-benchmark', command)
                self.assertEqual(command[command.index('-codexHome') + 1], environment['CODEX_HOME'])
                for key in ('CODEX_HOME',):
                    path = Path(environment[key])
                    self.assertTrue(path.is_relative_to(root / 'build'))
                    self.assertTrue(path.is_dir())
                self.assertNotIn('API_KEY', environment)
                self.assertNotIn('DSH_HOME', environment)
                launches.append((list(command), dict(environment)))

            def run(command, **kwargs):
                if command[0] == 'xcrun':
                    return SimpleNamespace(stdout='')
                self.assertIn('--diagnose', command)
                check_launch(command, kwargs['env'])
                if failure == 'preflight-interrupt':
                    raise KeyboardInterrupt()
                count = 0 if scenario == 'idle' else 3
                payload = {'tasks': [{'activity': 'running'} for _ in range(count)]}
                if supported is not None:
                    payload['energyBenchmarkIsolation'] = supported
                return SimpleNamespace(stdout=json.dumps(payload))

            def popen(command, **kwargs):
                if command[1] == 'hold':
                    return holder
                check_launch(command, kwargs['env'])
                self.assertEqual('--show-panel' in command, scenario == 'panel')
                if failure == 'launch':
                    raise OSError('Fixture app launch failed')
                return process

            with patch.object(energy, '__file__', str(root / 'scripts/measure_energy.py')), \
                 patch('sys.argv', ['measure_energy.py', '--app', str(app), '--scenario', scenario,
                                    '--seconds', '1', '--output', str(output)]), \
                 patch.dict(os.environ, {'CODEX_HOME': '/real-codex', 'DSH_HOME': '/real-dsh', 'API_KEY': 'fixture-canary'}), \
                 patch.object(energy.subprocess, 'run', side_effect=run), \
                 patch.object(energy.subprocess, 'Popen', side_effect=popen), \
                 patch.object(energy.time, 'sleep'), \
                 patch.object(energy.time, 'monotonic', side_effect=[0, 0, 0, 1, 1, 2]), \
                 patch.object(energy, 'wait_for_ready', side_effect=RuntimeError('Fixture readiness failed') if failure == 'readiness' else None), \
                 patch.object(energy, 'usage', side_effect=RuntimeError('Fixture sampling failed') if failure == 'sampling' else None,
                              return_value=energy.RUsage()), \
                 patch.object(energy, 'timebase', return_value=energy.MachTimebase(1, 1)), \
                 patch.object(energy.os, 'wait4', return_value=(42, 0, SimpleNamespace(ru_utime=0, ru_stime=0, ru_maxrss=0))), \
                 patch.object(energy.os, 'kill') as kill, \
                 patch('sys.stdout', new=io.StringIO()):
                if failure:
                    expected = {'launch': OSError, 'readiness': RuntimeError,
                                'preflight-interrupt': KeyboardInterrupt, 'sampling': RuntimeError}[failure]
                    with self.assertRaises(expected):
                        energy.main()
                    self.assertFalse(output.exists())
                    if failure == 'sampling':
                        kill.assert_called_once_with(process.pid, signal.SIGTERM)
                    else:
                        process.terminate.assert_not_called()
                elif supported:
                    energy.main()
                    self.assertEqual(len(launches), 2)
                    self.assertEqual(launches[0][1], launches[1][1])
                    self.assertEqual(json.loads(output.read_text())['verified_running_tasks'], 0 if scenario == 'idle' else 3)
                    kill.assert_called_once_with(process.pid, signal.SIGTERM)
                else:
                    with self.assertRaisesRegex(RuntimeError, 'rebuild the current source'):
                        energy.main()
                    self.assertEqual(len(launches), 1)
                    process.terminate.assert_not_called()
                    self.assertFalse(output.exists())
            if scenario != 'idle':
                holder.terminate.assert_called_once()
                holder.wait.assert_called_once_with(timeout=5)
                self.assertTrue(holder.stdout.closed)

    def testIdleIsolatesBothAppLaunches(self):
        self.exercise('idle')

    def testActiveIsolatesBothAppLaunches(self):
        self.exercise('active')

    def testPanelIsolatesBothAppLaunches(self):
        self.exercise('panel')

    def testOlderAppCannotProduceAnIsolationClaim(self):
        for supported in (None, False):
            with self.subTest(supported=supported):
                self.exercise('active', supported=supported)

    def testFailedAppLaunchReapsHolder(self):
        self.exercise('active', failure='launch')

    def testReadinessFailureReapsHolder(self):
        self.exercise('active', failure='readiness')

    def testInterruptedPreflightReapsHolder(self):
        self.exercise('active', failure='preflight-interrupt')

    def testSamplingFailureReapsBothProcesses(self):
        self.exercise('active', failure='sampling')

    def testCleanupKillsAnUnresponsiveFixture(self):
        process = Mock(returncode=None, stdout=io.BytesIO())
        process.wait.side_effect = [energy.subprocess.TimeoutExpired('fixture', 5), 0]
        energy.stop_process(process)
        process.terminate.assert_called_once()
        process.kill.assert_called_once()
        self.assertEqual(process.wait.call_count, 2)
        self.assertTrue(process.stdout.closed)

    def testInvalidDurationStartsNoProcesses(self):
        for seconds in ('0', '-1'):
            with self.subTest(seconds=seconds), \
                 patch('sys.argv', ['measure_energy.py', '--app', '/unused', '--scenario', 'idle',
                                    '--seconds', seconds, '--output', '/unused']), \
                 patch.object(energy.subprocess, 'Popen') as popen, \
                 patch.object(energy.subprocess, 'run') as run, \
                 patch('sys.stderr', new=io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    energy.main()
                self.assertEqual(error.exception.code, 2)
                popen.assert_not_called()
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
