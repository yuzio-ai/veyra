#!/usr/bin/env python3
"""Offline regression checks for cache invalidation and verification boundaries."""
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('verify_local', Path(__file__).with_name('verify_local.py'))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.root = self.base / 'repo'
        for folder in ('Veyra', 'VeyraTests', 'Veyra.xcodeproj', 'scripts'):
            (self.root / folder).mkdir(parents=True)
        (self.root / 'Veyra/example.swift').write_text('original')
        (self.root / 'Veyra/App').mkdir()
        (self.root / 'Veyra/App/VeyraApp.swift').write_text('--render-dashboard-previews DashboardPreview.render(')
        (self.root / 'Veyra/App/DashboardPreview.swift').write_text('fixture renderer')
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
        if name == 'tests-diagnostics-configuration':
            suite = verify.STATE / 'debug/Build/Products/Debug/VeyraTests.xctest/tests'
            suite.parent.mkdir(parents=True, exist_ok=True)
            suite.write_text('fixture tests')
        if name.startswith('previews-'):
            directory = output / name.removeprefix('previews-')
            directory.mkdir()
            (directory / 'layouts.json').write_text('[{"fixture": true}]')
            (directory / 'fixture.png').write_bytes(b'fixture')

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
            verify.run(verify.arguments(['test', '--only-testing', 'VeyraTests/HistoryIndexTests']))
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
            verify.run(verify.arguments(['previews', 'dashboard']))
            verify.run(verify.arguments(['previews', 'dashboard']))
            self.assertEqual([call.args[0] for call in execute.call_args_list],
                             ['tests-diagnostics-configuration', 'previews-en', 'previews-zh'])
            verify.run(verify.arguments(['previews', 'settings']))
            self.assertEqual(execute.call_count, 5)

    def testMissingPreviewEvidenceDoesNotPass(self):
        with patch.object(verify, 'execute', side_effect=self.fake_execute):
            verify.run(verify.arguments(['test']))
        with patch.object(verify, 'execute'):
            with self.assertRaises(FileNotFoundError):
                verify.run(verify.arguments(['previews', 'dashboard']))
        with patch.object(verify, 'execute', side_effect=self.fake_execute) as execute:
            verify.run(verify.arguments(['previews', 'dashboard']))
            self.assertEqual(execute.call_count, 2)

    def testLaunchRequiresCurrentVerifiedRelease(self):
        with patch.object(verify, 'execute', side_effect=self.fake_execute) as execute:
            with self.assertRaisesRegex(RuntimeError, 'release-build first'):
                verify.run(verify.arguments(['launch']))
            self.assertFalse(execute.called)

    def testDashboardWithoutFeatureCannotFallThroughToNormalLaunch(self):
        with patch.object(verify, 'execute') as execute:
            for missing in ('renderer', 'dispatch'):
                with self.subTest(missing=missing):
                    if missing == 'renderer':
                        (self.root / 'Veyra/App/DashboardPreview.swift').unlink()
                    else:
                        (self.root / 'Veyra/App/DashboardPreview.swift').write_text('fixture renderer')
                        (self.root / 'Veyra/App/VeyraApp.swift').write_text('normal launch only')
                    with self.assertRaisesRegex(RuntimeError, 'unavailable in this checkout'):
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
            popen.return_value.__enter__.return_value.wait.return_value = 0
            with self.assertRaisesRegex(RuntimeError, 'nonempty XCTest'):
                verify.execute('tests-diagnostics-configuration', ['/fixture'], 1, self.root / 'logs', {})


if __name__ == '__main__':
    unittest.main()
