#!/usr/bin/env python3
"""Offline deletion-boundary checks; never touch real applications or registrations."""
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('cleanup_apps', Path(__file__).with_name('cleanup_app_copies.py'))
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class AppCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / 'repo'
        (self.root / 'build').mkdir(parents=True)
        self.states = self.base / 'states'
        self.home = self.base / 'home'
        self.registered = set()
        self.read_registry = cleanup.registered_apps
        self.retire = cleanup.unregister
        self.patches = [patch.object(cleanup, 'ROOT', self.root),
                        patch.object(cleanup, 'TEMP_STATES', self.states),
                        patch.object(cleanup.Path, 'home', return_value=self.home),
                        patch.object(cleanup, 'registered_apps', side_effect=lambda: self.registered.copy()),
                        patch.object(cleanup, 'running_executables', return_value=[]),
                        patch.object(cleanup, 'unregister'),
                        patch('sys.stdout', new=io.StringIO())]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    def bundle(self, path, identity='ai.yuzio.veyra'):
        (path / 'Contents/MacOS').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identity}))
        (path / 'Contents/MacOS/Veyra').write_bytes(b'preserve this binary')
        self.registered.add(path)
        return path

    def testDryRunHasNoFilesystemOrRegistrationWrites(self):
        path = self.bundle(self.root / 'build/old/Veyra.app')
        before = sorted(self.base.rglob('*'))
        rows = cleanup.cleanup()
        self.assertEqual(rows, [{'path': str(path), 'action': 'remove-bundle'}])
        self.assertEqual(before, sorted(self.base.rglob('*')))
        cleanup.unregister.assert_not_called()

    def testInstalledAndArchiveBytesArePreserved(self):
        installed = self.bundle(self.home / 'Applications/Veyra.app')
        archived = self.bundle(self.home / 'Library/Developer/Xcode/Archives/release.xcarchive/Products/Applications/Veyra.app')
        before = {path: (path / 'Contents/MacOS/Veyra').read_bytes() for path in (installed, archived)}
        actions = {row['path']: row['action'] for row in cleanup.cleanup(True)}
        self.assertEqual(actions[str(installed)], 'keep-installed')
        self.assertEqual(actions[str(archived)], 'unregister-archive')
        cleanup.unregister.assert_called_once_with(archived)
        for path, content in before.items():
            self.assertEqual((path / 'Contents/MacOS/Veyra').read_bytes(), content)
        self.assertTrue(cleanup.installed(Path('/Applications/Veyra.app')))

    def testRemovesOnlyOwnedDisposableBundlesAndRetainsLogsAndZIP(self):
        paths = [self.bundle(self.root / 'Veyra.app'),
                 self.bundle(self.root / 'build/releases/v1.4.0/published-check/extracted/Veyra.app'),
                 self.bundle(self.states / ('a' * 16) / 'debug/Build/Products/Debug/Veyra.app'),
                 self.bundle(self.states / ('b' * 16) / 'focus-host/Veyra Keyboard Fixture.app',
                             'ai.yuzio.veyra.keyboard-focus-host'),
                 self.bundle(self.home / '.codex/worktrees/capture/veyra/build/Build/Products/Release/Veyra.app'),
                 self.bundle(self.home / 'Library/Developer/Xcode/DerivedData/Veyra-abc/Build/Products/Release/Veyra.app')]
        evidence = self.root / 'build/result.json'
        evidence.write_text('original evidence')
        zipped = self.root / 'build/releases/Veyra.zip'
        zipped.write_bytes(b'release zip')
        rows = cleanup.cleanup(True)
        self.assertEqual(sum(row['action'] == 'remove-bundle' for row in rows), len(paths))
        self.assertTrue(all(not path.exists() for path in paths))
        self.assertEqual(evidence.read_text(), 'original evidence')
        self.assertEqual(zipped.read_bytes(), b'release zip')
        self.assertEqual(cleanup.unregister.call_count, len(paths))

    def testRunningAndLockedBundlesAreSkipped(self):
        running = self.bundle(self.root / 'build/live/Veyra.app')
        state = self.states / ('c' * 16)
        busy = self.bundle(state / 'release/Build/Products/Release/Veyra.app')
        with cleanup.state_lock(state) as acquired:
            self.assertTrue(acquired)
            with patch.object(cleanup, 'running_executables', return_value=[running / 'Contents/MacOS/Veyra']):
                actions = {row['path']: row['action'] for row in cleanup.cleanup(True)}
        self.assertEqual(actions[str(running)], 'skip-running')
        self.assertEqual(actions[str(busy)], 'skip-busy')
        self.assertTrue(running.exists())
        self.assertTrue(busy.exists())
        cleanup.unregister.assert_not_called()

    def testSymlinkUnknownIdentityAndUnownedLocationsCannotBeDeleted(self):
        unrelated = self.bundle(self.root / 'build/unrelated/Veyra.app', 'example.other')
        unowned = self.bundle(self.home / 'Downloads/Veyra.app')
        source = self.bundle(self.home / 'source/Veyra.app')
        linked = self.root / 'build/Veyra.app'
        linked.symlink_to(source, target_is_directory=True)
        self.registered.add(linked)
        rows = cleanup.cleanup(True)
        self.assertTrue(all(path.exists() for path in (unrelated, unowned, source, linked)))
        self.assertIn({'path': str(linked), 'action': 'skip-symlink', 'applied': True}, rows)
        cleanup.unregister.assert_not_called()

    def testMissingRegistrationAndRepeatedCleanupAreIdempotent(self):
        missing = self.root / 'build/gone/Veyra.app'
        self.registered.add(missing)
        rows = cleanup.cleanup(True)
        self.assertEqual(rows[0]['action'], 'unregister-missing')
        cleanup.unregister.assert_called_once_with(missing)
        self.registered.clear()
        self.assertEqual(cleanup.cleanup(True), [])

    def testUnregisterFailureNeverDeletesBundle(self):
        path = self.bundle(self.root / 'build/old/Veyra.app')
        cleanup.unregister.side_effect = subprocess.CalledProcessError(1, ['fixture'])
        with self.assertRaises(subprocess.CalledProcessError):
            cleanup.cleanup(True)
        self.assertTrue(path.exists())

    def testIncompleteBundleRequiresExactVeyraRegistration(self):
        registered = self.root / 'build/interrupted/Veyra.app'
        unknown = self.root / 'build/unknown/Veyra.app'
        registered.mkdir(parents=True)
        unknown.mkdir(parents=True)
        self.registered.add(registered)
        cleanup.cleanup(True)
        self.assertFalse(registered.exists())
        self.assertTrue(unknown.exists())

    def testAutomaticRetirementPreservesFilesAndInstalledRegistration(self):
        installed = self.bundle(self.home / 'Applications/Veyra.app')
        build = self.bundle(self.root / 'build/Build/Products/Debug/Veyra.app')
        archived = self.bundle(self.home / 'release.xcarchive/Products/Applications/Veyra.app')
        unrelated = self.bundle(self.root / 'build/other/Veyra.app', 'example.other')
        cleanup.unregister_bundles([installed, build, unrelated], include_archives=True)
        self.assertEqual({call.args[0] for call in cleanup.unregister.call_args_list}, {build, archived})
        self.assertTrue(all(path.exists() for path in (installed, build, archived, unrelated)))

    def testInstalledAliasesCannotLoseTheirRegistration(self):
        installed = self.bundle(self.home / 'Applications/Veyra.app')
        alias = self.root / 'build/Veyra.app'
        alias.symlink_to(installed, target_is_directory=True)
        cleanup.unregister_bundles([alias, installed.parent / '../Applications/Veyra.app'])
        cleanup.unregister.assert_not_called()

    def testFailedBuildRetiresAnExactKnownRegistrationWithoutInfoPlist(self):
        incomplete = self.root / 'build/Build/Products/Debug/Veyra.app'
        incomplete.mkdir(parents=True)
        self.registered.add(incomplete)
        unknown = self.root / 'build/Build/Products/Release/Veyra.app'
        cleanup.unregister_bundles([incomplete, unknown])
        cleanup.unregister.assert_called_once_with(incomplete)

    def testRegistrationParserSelectsOnlyVeyraIdentities(self):
        dump = ('bundle id: Veyra\npath: /fixture/Veyra.app (0x123)\nidentifier: ai.yuzio.veyra\n'
                '--------------------------------------------------------------------------------\n'
                'path: /fixture/Other.app (0x124)\nidentifier: example.other\n')
        with patch.object(cleanup.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, dump)):
            self.assertEqual(self.read_registry(), {Path('/fixture/Veyra.app')})

    def testSpotlightScanErrorRequiresReadBackProvingUnregistration(self):
        path = Path('/fixture/Veyra.app')
        result = subprocess.CompletedProcess([], 1, 'failed to scan: -10814', '')
        with patch.object(cleanup.subprocess, 'run', return_value=result):
            self.retire(path)
            self.registered.add(path)
            with self.assertRaisesRegex(RuntimeError, 'Unable to unregister'):
                self.retire(path)

    def testUnavailableRegistryCannotMasqueradeAsSuccessfulCleanup(self):
        with patch.object(cleanup.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '')):
            with self.assertRaisesRegex(RuntimeError, 'outside the file sandbox'):
                self.read_registry()

    def testBuildExitTrapRetiresOnFailureAndPropagatesRetirementFailure(self):
        project = self.base / 'shell-fixture'
        scripts = project / 'scripts'
        scripts.mkdir(parents=True)
        build = scripts / 'build.sh'
        build.write_bytes(Path(__file__).with_name('build.sh').read_bytes())
        helper = scripts / 'cleanup_app_copies.py'
        helper.write_text('from pathlib import Path\nimport sys\n'
                          'root=Path(__file__).resolve().parent.parent\n'
                          '(root/"retired").write_text("\\n".join(sys.argv[1:]))\n'
                          'sys.exit(int((root/"cleanup-exit").read_text()))\n')
        fake = project / 'xcodebuild'
        env = dict(os.environ, PATH=str(project) + ':' + os.environ.get('PATH', ''))
        env.pop('VEYRA_DERIVED_DATA_PATH', None)
        for build_exit, cleanup_exit, expected in ((0, 0, 0), (7, 0, 7), (0, 9, 1)):
            with self.subTest(build_exit=build_exit, cleanup_exit=cleanup_exit):
                fake.write_text(f'#!/bin/zsh\nexit {build_exit}\n')
                fake.chmod(0o755)
                (project / 'cleanup-exit').write_text(str(cleanup_exit))
                result = subprocess.run(['/bin/zsh', '-f', str(build), '--unsigned'], env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual((project / 'retired').read_text().splitlines(),
                                 ['unregister', str(project / 'build/Build/Products/Release/Veyra.app')])


if __name__ == '__main__':
    unittest.main()
