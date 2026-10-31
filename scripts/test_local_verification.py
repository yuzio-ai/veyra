#!/usr/bin/env python3
"""Offline regression checks for cache invalidation and verification boundaries."""
import importlib.util
import io
import json
import os
import plistlib
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('verify_local', Path(__file__).with_name('verify_local.py'))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


INTERRUPTION_RUNNER = r'''
import importlib.util,sys,time
from pathlib import Path
from unittest.mock import patch
source,directory,mode=sys.argv[1:]
spec=importlib.util.spec_from_file_location('verify',source)
verify=importlib.util.module_from_spec(spec);spec.loader.exec_module(verify)
root=Path(directory);verify.ROOT=root/'repo';verify.ROOT.mkdir()
verify.STATE=root/'state';verify.OUTPUT=root/'output'
worker='import os,signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);print("WORKER "+str(os.getpid()),flush=True);time.sleep(30)'
verify.source_digest=lambda:'fixture-source'
verify.toolchain_digest=lambda env:'fixture-toolchain'
verify.commands=lambda options,output:[('worker',[sys.executable,'-I','-B','-c',worker],0.5 if mode=='timeout' else 30)]
original=verify.subprocess.Popen
class ObservedProcess(original):
    def wait(self,timeout=None):
        if timeout==5:
            (root/'reaping').touch()
            deadline=time.monotonic()+5
            while not (root/'release').exists():
                if time.monotonic()>deadline: raise RuntimeError('Controller did not release cleanup')
                time.sleep(0.01)
        return super().wait(timeout=timeout)
sys.argv=['verify_local.py','test','--force']
with patch.object(verify.subprocess,'Popen',ObservedProcess):
    raise SystemExit(verify.main())
'''


class VerificationInterruptionTests(unittest.TestCase):
    def testRealRunStopsWorkerBeforeUnlockAndCannotCacheInterruptedSuccess(self):
        for mode, signum in [('term', signal.SIGTERM), ('int', signal.SIGINT), ('timeout', None)]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix='veyra-verification-interrupt-') as directory:
                root = Path(directory)
                runner = subprocess.Popen([sys.executable, '-I', '-B', '-c', INTERRUPTION_RUNNER,
                    str(Path(verify.__file__).resolve()), directory, mode], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                worker = None
                try:
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        logs = list((root / 'output').glob('*/worker.log'))
                        if logs and logs[0].read_text().startswith('WORKER '):
                            worker = int(logs[0].read_text().split()[1]); break
                        time.sleep(0.01)
                    self.assertIsNotNone(worker, 'The isolated worker must start')
                    if signum is not None: os.kill(runner.pid, signum)
                    deadline = time.monotonic() + 5
                    while not (root / 'reaping').exists() and time.monotonic() < deadline:
                        self.assertIsNone(runner.poll(), 'Verifier must enter cleanup instead of exiting on the signal')
                        time.sleep(0.01)
                    self.assertTrue((root / 'reaping').exists())
                    with self.assertRaisesRegex(RuntimeError, 'Another Veyra verification'):
                        with verify.lock(root / 'state'): pass
                    # Repeated signals, and a first signal during timeout cleanup, must
                    # leave the lock held until the actual wait/reap has completed.
                    os.kill(runner.pid, signum if signum is not None else signal.SIGTERM)
                    time.sleep(0.03)
                    self.assertIsNone(runner.poll())
                    with self.assertRaisesRegex(RuntimeError, 'Another Veyra verification'):
                        with verify.lock(root / 'state'): pass
                    (root / 'release').touch()
                    stdout, stderr = runner.communicate(timeout=5)
                    self.assertEqual(runner.returncode, 128 + signum if signum is not None else 1, stderr)
                    with self.assertRaises(ProcessLookupError): os.kill(worker, 0)
                    with verify.lock(root / 'state'): pass
                    results = list((root / 'output').glob('*/result.json'))
                    self.assertEqual(len(results), 1)
                    self.assertEqual(json.loads(results[0].read_text())['status'], 'failed')
                    self.assertEqual(list((root / 'state').glob('success-*.json')), [])
                    self.assertNotIn('PASS ', stdout)
                finally:
                    (root / 'release').touch()
                    if worker is not None:
                        try: os.killpg(worker, signal.SIGKILL)
                        except ProcessLookupError: pass
                    if runner.poll() is None: runner.kill()
                    runner.communicate(timeout=5)


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.root = self.base / 'repo'
        for folder in ('Veyra', 'VeyraTests', 'Veyra.xcodeproj', 'scripts'):
            (self.root / folder).mkdir(parents=True)
        (self.root / 'Veyra/example.swift').write_text('original')
        self.patches = [patch.object(verify, 'ROOT', self.root), patch.object(verify, 'STATE', self.base / 'state'),
                        patch.object(verify, 'OUTPUT', self.root / 'build/local-verification'),
                        patch.object(verify, 'source_digest', side_effect=lambda: verify.tree_digest([self.root / 'Veyra/example.swift'])),
                        patch.object(verify, 'toolchain_digest', return_value='toolchain-1'),
                        patch('sys.stdout', new=io.StringIO()), patch('sys.stderr', new=io.StringIO())]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)
        self.addCleanup(self.temporary.cleanup)

    def fake_execute(self, name, command, timeout, output, env):
        (output / (name + '.log')).write_text('fixture success')
        configuration = 'Release' if name == 'release-build' else 'Debug'
        built = verify.binary(configuration)
        built.parent.mkdir(parents=True, exist_ok=True)
        built.write_text('fixture binary')
        (verify.app(configuration) / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.veyra.fixture'}))
        if name == 'tests-diagnostics-configuration':
            suite = verify.STATE / 'debug/Build/Products/Debug/VeyraTests.xctest/tests'
            suite.parent.mkdir(parents=True, exist_ok=True)
            suite.write_text('fixture tests')
        if name.startswith('previews-'):
            directory = output / name.removeprefix('previews-')
            directory.mkdir()
            names = ('dsh-only-light', 'dsh-idle-light', 'dsh-unknown-light', 'dsh-error-light', 'no-sources-light',
                     'mixed-error-light', 'settings-missing-light', 'settings-dsh-models-light')
            (directory / 'layouts.json').write_text(json.dumps([{'name': name} for name in names]))
            (directory / 'fixture.png').write_bytes(b'fixture')
            if '--exercise-settings' in command:
                (directory / 'settings-native-checks.json').write_text(json.dumps({'passed': [
                    'dsh-path-commit', 'dsh-invalid-draft', 'dsh-close-and-reopen', 'dsh-restore']}))
        if name.startswith('native-menu-'):
            directory = Path(command[command.index('--exercise-menu-to') + 1])
            directory.mkdir(parents=True)
            (directory / 'menu-check.json').write_text(json.dumps([
                {'toggleAndEscapePassed': True, 'appWasActive': True, 'windowWasKey': True,
                 'openedFromBackground': True, 'previousApplicationRestored': True},
                {'position': 'dsh-only', 'providerHidden': True, 'quotaHidden': True, 'escapePassed': True,
                 'appWasActive': True, 'windowWasKey': True,
                 'openedFromBackground': True, 'previousApplicationRestored': True}]))

    def testUnchangedSuccessSkipsButForceRuns(self):
        with patch.object(verify, 'execute', side_effect=self.fake_execute) as execute:
            verify.run(verify.arguments(['test']))
            verify.run(verify.arguments(['test']))
            self.assertEqual(execute.call_count, 1)
            verify.run(verify.arguments(['test', '--force']))
            self.assertEqual(execute.call_count, 2)

    def testSourceToolchainAndArtifactChangesInvalidateSuccess(self):
        with patch.object(verify, 'execute', side_effect=self.fake_execute) as execute:
            verify.run(verify.arguments(['test']))
            (self.root / 'Veyra/example.swift').write_text('changed')
            verify.run(verify.arguments(['test']))
            verify.binary('Debug').write_text('changed binary')
            verify.run(verify.arguments(['test']))
            with patch.object(verify, 'toolchain_digest', return_value='toolchain-2'):
                verify.run(verify.arguments(['test']))
            self.assertEqual(execute.call_count, 4)

    def testFailureRemovesPreviousSuccessAndRunsAgain(self):
        with patch.object(verify, 'execute', side_effect=self.fake_execute):
            verify.run(verify.arguments(['test']))
        with patch.object(verify, 'execute', side_effect=RuntimeError('fixture failure')):
            with self.assertRaises(RuntimeError):
                verify.run(verify.arguments(['test', '--force']))
        with patch.object(verify, 'execute', side_effect=self.fake_execute) as execute:
            verify.run(verify.arguments(['test']))
            self.assertEqual(execute.call_count, 1)

    def testMissingOrCorruptedEvidenceInvalidatesSuccess(self):
        with patch.object(verify, 'execute', side_effect=self.fake_execute) as execute:
            verify.run(verify.arguments(['test']))
            first = next(verify.OUTPUT.glob('*/tests-diagnostics-configuration.log'))
            first.write_text('corrupted evidence')
            verify.run(verify.arguments(['test']))
            for result in verify.OUTPUT.glob('*/result.json'):
                result.unlink()
            verify.run(verify.arguments(['test']))
            self.assertEqual(execute.call_count, 3)

    def testFocusedSuccessDoesNotReplaceFullSuite(self):
        with patch.object(verify, 'execute', side_effect=self.fake_execute) as execute:
            verify.run(verify.arguments(['test', '--only-testing', 'VeyraTests/MonitorStoreTests']))
            verify.run(verify.arguments(['test']))
            self.assertEqual(execute.call_count, 2)

    def testChangingInputsDuringRunDoesNotCreateSuccess(self):
        def mutate(*args):
            self.fake_execute(*args)
            (self.root / 'Veyra/example.swift').write_text('concurrent edit')
        with patch.object(verify, 'execute', side_effect=mutate):
            with self.assertRaisesRegex(RuntimeError, 'inconclusive'):
                verify.run(verify.arguments(['test']))
        self.assertEqual(list(verify.STATE.glob('success-*.json')), [])
        result = json.loads(next(verify.OUTPUT.glob('*/result.json')).read_text())
        self.assertEqual(result['status'], 'failed')

    def testConcurrentInvocationDoesNotPass(self):
        with verify.lock(verify.STATE):
            with self.assertRaisesRegex(RuntimeError, 'did not run'):
                with verify.lock(verify.STATE):
                    self.fail('second verification acquired the lock')

    def testPreviewReusesDebugBuildWithoutRepeatingTests(self):
        with patch.object(verify, 'execute', side_effect=self.fake_execute) as execute:
            verify.run(verify.arguments(['test']))
            verify.run(verify.arguments(['previews', 'settings']))
            verify.run(verify.arguments(['previews', 'settings']))
            self.assertEqual([call.args[0] for call in execute.call_args_list],
                             ['tests-diagnostics-configuration', 'previews-en', 'previews-zh'])
            verify.run(verify.arguments(['previews', 'settings', '--language', 'en']))
            self.assertEqual(execute.call_count, 4)

    def testMissingPreviewEvidenceDoesNotPass(self):
        with patch.object(verify, 'execute', side_effect=self.fake_execute):
            verify.run(verify.arguments(['test']))
        with patch.object(verify, 'execute'):
            with self.assertRaises(FileNotFoundError):
                verify.run(verify.arguments(['previews', 'settings']))
        with patch.object(verify, 'execute', side_effect=self.fake_execute) as execute:
            verify.run(verify.arguments(['previews', 'settings']))
            self.assertEqual(execute.call_count, 2)

    def testNativeMenuChecksUseOnlyFixedIsolatedPreviewCommands(self):
        with patch.object(verify, 'execute', side_effect=self.fake_execute) as execute:
            verify.run(verify.arguments(['previews', 'menu']))
            native = [call.args for call in execute.call_args_list if call.args[0].startswith('native-menu-')]
            self.assertEqual(len(native), 6)
            for name, command, timeout, output, env in native:
                self.assertEqual(command[:4], ['/usr/bin/open', '-n', '-W', '-a'])
                self.assertEqual(command[4], str(verify.app('Debug')))
                self.assertIn('--args', command)
                self.assertEqual(command[command.index('--env') + 1], 'CODEX_HOME=' + str(output / 'fixture-codex-home'))
                uuid.UUID(command[command.index('--preview-lease') + 1])
                self.assertTrue(Path(command[command.index('--stdout') + 1]).is_relative_to(output))
                self.assertEqual(command[command.index('--preview-menu') + 1], 'multiple')
                self.assertIn('--exit-after-menu-checks', command)
                self.assertEqual(env['CODEX_HOME'], str(output / 'fixture-codex-home'))
                self.assertTrue(Path(command[command.index('--exercise-menu-to') + 1]).is_relative_to(output))

    def testLayoutChecksAlsoUseIsolatedSystemLaunchAndRequireAResult(self):
        with patch.object(verify, 'execute', side_effect=self.fake_execute) as execute:
            verify.run(verify.arguments(['previews', 'menu']))
            layouts = [call.args for call in execute.call_args_list if call.args[0].startswith('previews-')]
            self.assertEqual(len(layouts), 2)
            for name, command, timeout, output, env in layouts:
                self.assertEqual(command[:5], ['/usr/bin/open', '-n', '-W', '-a', str(verify.app('Debug'))])
                self.assertEqual(command[command.index('--env') + 1], 'CODEX_HOME=' + str(output / 'fixture-codex-home'))
                uuid.UUID(command[command.index('--preview-lease') + 1])
                self.assertTrue(Path(command[command.index('--render-previews') + 1]).is_relative_to(output))

    def testDshPreviewsAreIsolatedAndCannotReplaceFullPreviewEvidence(self):
        with patch.object(verify, 'execute', side_effect=self.fake_execute) as execute:
            verify.run(verify.arguments(['previews', 'menu', '--dsh-only']))
            previews = [call.args for call in execute.call_args_list if call.args[0].startswith('previews-')]
            self.assertEqual(len(previews), 2)
            for name, command, timeout, output, env in previews:
                self.assertIn('--preview-dsh-only', command)
                self.assertEqual(env['CODEX_HOME'], str(output / 'fixture-codex-home'))
            execute.reset_mock()
            verify.run(verify.arguments(['previews', 'menu']))
            self.assertTrue(any(call.args[0] == 'previews-en' for call in execute.call_args_list))

    def testDshPreviewsRejectMissingCapabilityEvidence(self):
        def incomplete(name, command, timeout, output, env):
            self.fake_execute(name, command, timeout, output, env)
            if name.startswith('previews-'):
                directory = Path(command[command.index('--render-previews') + 1])
                (directory / 'layouts.json').write_text('[{"fixture": true}]')
        with patch.object(verify, 'execute', side_effect=incomplete):
            with self.assertRaisesRegex(RuntimeError, 'dsh capability'):
                verify.run(verify.arguments(['previews', 'menu', '--dsh-only']))

    def testDshOnlyRejectsSettingsTarget(self):
        with self.assertRaises(SystemExit):
            verify.arguments(['previews', 'settings', '--dsh-only'])

    def testNativeOnlyRunsFixedChecksAndCannotReplaceFullPreviewEvidence(self):
        with patch.object(verify, 'execute', side_effect=self.fake_execute) as execute:
            verify.run(verify.arguments(['previews', 'menu', '--native-only']))
            names = [call.args[0] for call in execute.call_args_list]
            self.assertEqual(len([name for name in names if name.startswith('native-menu-')]), 6)
            self.assertFalse(any(name.startswith('previews-') for name in names))
            execute.reset_mock()
            verify.run(verify.arguments(['previews', 'menu']))
            names = [call.args[0] for call in execute.call_args_list]
            self.assertIn('previews-en', names)
            self.assertIn('previews-zh', names)
            self.assertEqual(len([name for name in names if name.startswith('native-menu-')]), 6)

    def testNativeOnlyRejectsOtherPreviewTargets(self):
        for target in ('settings',):
            with self.assertRaises(SystemExit):
                verify.arguments(['previews', target, '--native-only'])

    def testNativeMenuCannotPassWithoutActiveKeyWindowEvidence(self):
        def inactive(name, command, timeout, output, env):
            self.fake_execute(name, command, timeout, output, env)
            if name.startswith('native-menu-'):
                path = Path(command[command.index('--exercise-menu-to') + 1]) / 'menu-check.json'
                records = json.loads(path.read_text())
                records[0]['windowWasKey'] = False
                path.write_text(json.dumps(records))
        with patch.object(verify, 'execute', side_effect=inactive):
            with self.assertRaisesRegex(RuntimeError, 'interaction evidence'):
                verify.run(verify.arguments(['previews', 'menu', '--native-only']))

    def testNativeMenuRequiresBackgroundOpeningAndFocusRestorationForBothSources(self):
        for source in (0, 1):
            for field in ('openedFromBackground', 'previousApplicationRestored'):
                def incomplete(name, command, timeout, output, env):
                    self.fake_execute(name, command, timeout, output, env)
                    if name.startswith('native-menu-'):
                        path = Path(command[command.index('--exercise-menu-to') + 1]) / 'menu-check.json'
                        records = json.loads(path.read_text())
                        records[source].pop(field)
                        path.write_text(json.dumps(records))
                with self.subTest(source=source, field=field), patch.object(verify, 'execute', side_effect=incomplete):
                    with self.assertRaisesRegex(RuntimeError, 'interaction evidence'):
                        verify.run(verify.arguments(['previews', 'menu', '--native-only']))

    def testFocusHostHasSeparateIdentityWithoutChangingVerifiedApp(self):
        source = verify.app('Debug') / 'Contents/Info.plist'
        source.parent.mkdir(parents=True)
        original = plistlib.dumps({'CFBundleIdentifier': 'com.veyra.fixture', 'LSUIElement': True})
        source.write_bytes(original)
        verify.prepare_focus_host_app()
        copied = plistlib.loads((verify.focus_host_app() / 'Contents/Info.plist').read_bytes())
        self.assertEqual(copied['CFBundleIdentifier'], 'com.veyra.fixture.keyboard-focus-host')
        self.assertFalse(copied['LSUIElement'])
        self.assertEqual(source.read_bytes(), original)

    def testLaunchRequiresCurrentVerifiedRelease(self):
        with patch.object(verify, 'execute', side_effect=self.fake_execute) as execute:
            with self.assertRaisesRegex(RuntimeError, 'release-build first'):
                verify.run(verify.arguments(['launch']))
            self.assertFalse(execute.called)

    def testLaunchPreservesExplicitCodexHomeWithoutCreatingAFixture(self):
        with patch.dict(verify.os.environ, {'CODEX_HOME': '/fixture/user-selected-codex'}, clear=True), \
                patch.object(verify, 'execute', side_effect=self.fake_execute) as execute:
            verify.run(verify.arguments(['release-build']))
            verify.run(verify.arguments(['launch']))
            name, command, timeout, output, env = execute.call_args.args
            self.assertEqual(name, 'launch')
            self.assertEqual(env['CODEX_HOME'], '/fixture/user-selected-codex')
            self.assertFalse((output / 'fixture-codex-home').exists())

    def testLaunchWithoutCodexHomeRetainsApplicationDefaultDiscovery(self):
        with patch.dict(verify.os.environ, {}, clear=True), \
                patch.object(verify, 'execute', side_effect=self.fake_execute) as execute:
            verify.run(verify.arguments(['release-build']))
            verify.run(verify.arguments(['launch']))
            name, command, timeout, output, env = execute.call_args.args
            self.assertEqual(name, 'launch')
            self.assertNotIn('CODEX_HOME', env)
            self.assertFalse((output / 'fixture-codex-home').exists())

    def testRemovedPreviewTargetCannotFallThroughToNormalLaunch(self):
        with patch.object(verify, 'execute') as execute:
            with self.assertRaises(SystemExit):
                verify.run(verify.arguments(['previews', 'dashboard']))
            self.assertFalse(execute.called)
        self.assertFalse(verify.STATE.exists())

    def testDryRunDoesNotExecuteOrCreateState(self):
        with patch.object(verify, 'execute') as execute:
            verify.run(verify.arguments(['test', '--dry-run']))
            self.assertFalse(execute.called)
        self.assertFalse(verify.STATE.exists())
        self.assertFalse(verify.OUTPUT.exists())

    def testRejectArbitraryCommandsFlagsPathsAndTargets(self):
        for argv in (['install-rules'], ['test', '--only-testing', '../../OtherTests'],
                     ['test', '--only-testing', 'VeyraTests/A;open'], ['test', '--derived-data', '/tmp/other'],
                     ['previews', '../../other'], ['launch', '--force'], ['ax-read', '-1'],
                     ['ax-read', '12', '--press', 'Save']):
            with self.subTest(argv=argv), self.assertRaises(SystemExit):
                verify.arguments(argv)

    def testZeroTestRunCannotPass(self):
        self.root.joinpath('logs').mkdir()
        with patch.object(verify.subprocess, 'Popen') as popen:
            popen.return_value.wait.return_value = 0
            with self.assertRaisesRegex(RuntimeError, 'nonempty XCTest'):
                verify.execute('tests-diagnostics-configuration', ['/fixture'], 1, self.root / 'logs', {})

    def testFailedWorkerReapDoesNotEnterAnUnboundedContextManagerWait(self):
        self.root.joinpath('logs').mkdir()
        with patch.object(verify.subprocess, 'Popen') as popen, patch.object(verify.os, 'killpg'):
            popen.return_value.wait.side_effect = [subprocess.TimeoutExpired('fixture', 1), subprocess.TimeoutExpired('fixture', 5)]
            with self.assertRaises(subprocess.TimeoutExpired):
                verify.execute('fixture', ['/fixture'], 1, self.root / 'logs', {})
            self.assertEqual(popen.return_value.wait.call_count, 2)


class NativeFixtureCleanupTests(unittest.TestCase):
    def fixture(self, directory, token):
        # A real detached process models LaunchServices' separate process group.
        worker = '''import json,os,sys,time
from pathlib import Path
directory,token=sys.argv[1:3]
Path(directory,'process.json').write_text(json.dumps({'pid':os.getpid(),'group':os.getpgrp(),'token':token}))
time.sleep(30)
'''
        process = subprocess.Popen([sys.executable, '-I', '-B', '-c', worker, str(directory), token,
                                    '--preview-lease', token], start_new_session=True)
        def cleanup():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
        self.addCleanup(cleanup)
        deadline = time.monotonic() + 5
        while not (directory / 'process.json').exists():
            if time.monotonic() >= deadline:
                self.fail('Detached fixture did not start')
            time.sleep(0.01)
        return process

    def testDetachedFixtureIsStoppedAndLeaseIsRevoked(self):
        with tempfile.TemporaryDirectory(prefix='veyra-native-cleanup-') as name:
            directory = Path(name)
            token = str(uuid.uuid4())
            (directory / 'active-lease').write_text(token)
            process = self.fixture(directory, token)
            executable = verify.executable_path(process.pid)
            self.assertIsNotNone(executable)
            verify.stop_preview_fixture(directory, executable, token)
            self.assertEqual(process.wait(timeout=5), -signal.SIGKILL)
            self.assertFalse((directory / 'active-lease').exists())

    def testChangedTokenOrExecutableCannotSignalAnotherProcess(self):
        with tempfile.TemporaryDirectory(prefix='veyra-native-identity-') as name:
            directory = Path(name)
            token = str(uuid.uuid4())
            process = self.fixture(directory, token)
            executable = verify.executable_path(process.pid)
            with self.assertRaisesRegex(RuntimeError, 'receipt'):
                verify.stop_preview_fixture(directory, executable, str(uuid.uuid4()))
            self.assertIsNone(process.poll())
            with self.assertRaisesRegex(RuntimeError, 'identity'):
                verify.stop_preview_fixture(directory, directory / 'wrong-binary', token)
            self.assertIsNone(process.poll())
            verify.stop_preview_fixture(directory, executable, token)
            process.wait(timeout=5)

    def testGracefulExitDuringArgumentReadDoesNotFailCleanup(self):
        with tempfile.TemporaryDirectory(prefix='veyra-native-graceful-exit-') as name:
            directory = Path(name)
            token = str(uuid.uuid4())
            process = self.fixture(directory, token)
            executable = verify.executable_path(process.pid)
            def exited(*args, **kwargs):
                process.terminate(); process.wait(timeout=5)
                return subprocess.CompletedProcess(args[0], 1, stdout='')
            with patch.object(verify.subprocess, 'run', side_effect=exited):
                verify.stop_preview_fixture(directory, executable, token)
            self.assertEqual(process.returncode, -signal.SIGTERM)

    def testLaunchFailureRevokesLeaseAndCannotBecomeSuccess(self):
        with tempfile.TemporaryDirectory(prefix='veyra-native-open-') as name:
            directory = Path(name)
            token = str(uuid.uuid4())
            command = ['/usr/bin/open', '--exercise-menu-to', str(directory / 'fixture'), '--preview-lease', token]
            with patch.object(verify.subprocess, 'Popen', side_effect=OSError('fixture launch failure')):
                with self.assertRaises(OSError):
                    verify.execute('native-menu-light', command, 1, directory, {})
            self.assertFalse((directory / 'fixture/active-lease').exists())
            with patch.object(verify.subprocess, 'Popen') as launch:
                launch.return_value.wait.return_value = 0
                with self.assertRaisesRegex(RuntimeError, 'no successful GUI preview result'):
                    verify.execute('native-menu-light', command, 1, directory, {})
            render_command = ['/usr/bin/open', '--render-previews', str(directory / 'layouts'), '--preview-lease', token]
            with patch.object(verify.subprocess, 'Popen') as launch:
                launch.return_value.wait.return_value = 0
                with self.assertRaisesRegex(RuntimeError, 'no successful GUI preview result'):
                    verify.execute('previews-en', render_command, 1, directory, {})
            self.assertFalse((directory / 'layouts/active-lease').exists())

    def testTimeoutAndInterruptionStopDetachedAppBeforeReturning(self):
        original = subprocess.Popen
        for mode in ('timeout', 'interrupt'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix='veyra-native-interrupt-') as name:
                directory = Path(name)
                token = str(uuid.uuid4())
                (directory / 'active-lease').write_text(token)
                child = self.fixture(directory, token)
                fixture = (directory, verify.executable_path(child.pid), token)
                class Opener(original):
                    def wait(self, timeout=None):
                        if mode == 'interrupt' and timeout == 0.1:
                            raise KeyboardInterrupt()
                        return super().wait(timeout=timeout)
                with patch.object(verify, 'preview_fixture', return_value=fixture), \
                        patch.object(verify.subprocess, 'Popen', Opener):
                    with self.assertRaises(KeyboardInterrupt if mode == 'interrupt' else RuntimeError):
                        verify.execute('native-menu-light', [sys.executable, '-I', '-B', '-c', 'import time; time.sleep(30)'],
                                       0.1, directory, {})
                self.assertEqual(child.wait(timeout=5), -signal.SIGKILL)
                self.assertFalse((directory / 'active-lease').exists())


if __name__ == '__main__':
    unittest.main()
