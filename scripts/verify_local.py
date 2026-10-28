#!/usr/bin/env python3
"""Fixed, unsigned local verification. No shell strings or arbitrary tool arguments."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
import platform
from pathlib import Path
import re
import signal
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parent.parent
STATE = Path('/private/tmp/veyra-local-verification') / hashlib.sha256(str(ROOT).encode()).hexdigest()[:16]
OUTPUT = ROOT / 'build/local-verification'
PYTHON = '/usr/bin/python3'
SELECTOR = re.compile(r'VeyraTests(?:/[A-Za-z_][A-Za-z0-9_]*){1,2}')


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    modes = parser.add_subparsers(dest='mode', required=True)
    for mode in ('test', 'release-build', 'previews', 'launch', 'ax-read'):
        child = modes.add_parser(mode, allow_abbrev=False)
        child.add_argument('--dry-run', action='store_true', help='Print the fixed commands without running them')
        if mode in ('test', 'release-build', 'previews'):
            child.add_argument('--force', action='store_true', help='Ignore a previous successful verification')
        if mode == 'test':
            child.add_argument('--only-testing', help='VeyraTests/TestClass[/testMethod]; never counts as a full suite')
        if mode == 'previews':
            child.add_argument('target', choices=('dashboard', 'menu', 'settings'))
            child.add_argument('--language', choices=('en', 'zh', 'both'), default='both')
            child.add_argument('--native-only', action='store_true', help='Run only the six fixed fixture popover checks (menu only)')
        if mode == 'launch':
            child.add_argument('--language', choices=('en', 'zh'), default='zh')
        if mode == 'ax-read':
            child.add_argument('pid', type=int)
    result = parser.parse_args(argv)
    if getattr(result, 'only_testing', None) and not SELECTOR.fullmatch(result.only_testing):
        parser.error('--only-testing must be VeyraTests/TestClass[/testMethod]')
    if result.mode == 'ax-read' and result.pid <= 0:
        parser.error('pid must be positive')
    if result.mode == 'previews' and result.native_only and result.target != 'menu':
        parser.error('--native-only requires previews menu')
    return result


def environment():
    # Keep toolchain selection, but do not forward command injection or account variables.
    names = ('PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL', 'TZ', 'DEVELOPER_DIR')
    return {name: os.environ[name] for name in names if name in os.environ}


def tree_digest(paths):
    digest = hashlib.sha256()
    for path in sorted(paths):
        if path.is_symlink():
            digest.update(str(path).encode() + b'\0link\0' + os.readlink(path).encode())
        elif path.is_file():
            digest.update(str(path).encode() + b'\0' + path.read_bytes())
        else:
            raise FileNotFoundError(path)
    return digest.hexdigest()


def source_digest(root=ROOT):
    paths = []
    for folder in ('Veyra', 'VeyraTests', 'Veyra.xcodeproj', 'scripts'):
        paths.extend(path for path in (root / folder).rglob('*') if path.is_file()
                     and 'xcuserdata' not in path.parts and '__pycache__' not in path.parts)
    paths.extend(root.glob('*.xcconfig'))
    return tree_digest(paths)


def artifact_digest(paths):
    files = []
    for path in paths:
        if not path.exists():
            return None
        files.extend(path.rglob('*') if path.is_dir() else [path])
    return tree_digest([path for path in files if path.is_file() or path.is_symlink()])


def toolchain_digest(env):
    digest = hashlib.sha256(json.dumps(env, sort_keys=True).encode())
    digest.update(platform.platform().encode())
    for command in (['/usr/bin/xcodebuild', '-version'], ['/usr/bin/xcrun', 'swiftc', '--version']):
        result = subprocess.run(command, env=env, capture_output=True, check=True, timeout=30)
        digest.update(result.stdout)
    return digest.hexdigest()


def fingerprint(source, toolchain, scope):
    return hashlib.sha256(json.dumps([source, toolchain, scope], sort_keys=True).encode()).hexdigest()


def stamp_path(key):
    return STATE / ('success-' + hashlib.sha256(key.encode()).hexdigest()[:16] + '.json')


def cached(path, expected, artifacts):
    try:
        record = json.loads(path.read_text())
        output = Path(record['output'])
        if output.parent != OUTPUT or json.loads((output / 'result.json').read_text())['status'] != 'passed':
            return None
        logs = list(output.glob('*.log'))
        if not logs or record['logs'] != tree_digest(logs):
            return None
        actual = artifact_digest(artifacts)
        return record if record['fingerprint'] == expected and actual is not None and record['artifacts'] == actual else None
    except (OSError, ValueError, KeyError, TypeError):
        return None


def save_stamp(path, expected, artifacts, output):
    actual = artifact_digest(artifacts)
    if actual is None:
        raise RuntimeError('Expected verification artifacts are missing')
    logs = list(output.glob('*.log'))
    if not logs:
        raise RuntimeError('Expected verification logs are missing')
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps({'fingerprint': expected, 'artifacts': actual, 'output': str(output),
                                     'logs': tree_digest(logs)}, indent=2))
    temporary.replace(path)


@contextmanager
def lock(directory=None):
    directory = STATE if directory is None else directory
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / 'verification.lock').open('a') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another Veyra verification is running; this invocation did not run') from None
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def app(configuration):
    return STATE / configuration.lower() / 'Build/Products' / configuration / 'Veyra.app'


def binary(configuration):
    return app(configuration) / 'Contents/MacOS/Veyra'


def language(locale):
    return ['-AppleLanguages', '(en)' if locale == 'en' else '("zh-Hans")',
            '-AppleLocale', 'en_US' if locale == 'en' else 'zh_CN']


def commands(options, output):
    if options.mode == 'test':
        command = ['/bin/zsh', '-f', str(ROOT / 'scripts/test.sh'), '--unsigned']
        if options.only_testing:
            command += ['--only-testing', options.only_testing]
        return [('tests-diagnostics-configuration', command, 900)]
    if options.mode == 'release-build':
        return [('release-build', ['/bin/zsh', '-f', str(ROOT / 'scripts/build.sh'), '--unsigned'], 900),
                ('release-configuration', [PYTHON, '-I', '-B', str(ROOT / 'scripts/verify_configuration.py'),
                                           '--derived-data', str(STATE / 'release')], 60),
                ('ax-reader-build', ['/usr/bin/xcrun', 'swiftc', '-swift-version', '6',
                                     str(ROOT / 'scripts/accessibility_snapshot.swift'), '-o', str(STATE / 'accessibility-snapshot')], 120)]
    if options.mode == 'previews':
        locales = ('en', 'zh') if options.language == 'both' else (options.language,)
        flag = '--render-dashboard-previews' if options.target == 'dashboard' else '--render-previews'
        extra = ['--preview-settings-only'] if options.target == 'settings' else []
        plan = [('previews-' + locale, [str(binary('Debug')), flag, str(output / locale)] + extra + language(locale), 300)
                for locale in locales]
        if options.native_only:
            plan = []
        if options.target == 'menu':
            # Fixed fixture popovers only: no live launch, real Codex home, global hotkey, or network.
            for style in ('light', 'dark', 'light-increased', 'dark-increased', 'light-opaque', 'dark-opaque'):
                appearance = style.removesuffix('-opaque')
                command = [str(binary('Debug')), '--preview-menu', 'multiple', '--show-menu',
                           '--preview-appearance', appearance, '--exercise-menu-to', str(output / locales[0] / ('native-' + style)),
                           '--exit-after-menu-checks'] + language(locales[0])
                if style.endswith('-opaque'):
                    command.append('--preview-reduce-transparency')
                plan.append(('native-menu-' + style, command, 40))
        return plan
    if options.mode == 'launch':
        return [('launch', ['/usr/bin/open', '-n', str(app('Release')), '--args'] + language(options.language), 30)]
    helper = STATE / 'accessibility-snapshot'
    return [('compile-ax-reader', ['/usr/bin/xcrun', 'swiftc', '-swift-version', '6', str(ROOT / 'scripts/accessibility_snapshot.swift'), '-o', str(helper)], 120),
            ('ax-read', [str(helper), str(options.pid), str(output / 'accessibility.json'),
                         str(app('Debug')), str(app('Release'))], 60)]


def execute(name, command, timeout, output, env):
    log = output / (name + '.log')
    print(f'RUN {name}: {log}', flush=True)
    with log.open('wb') as handle:
        with subprocess.Popen(command, cwd=ROOT, env=env, stdout=handle, stderr=subprocess.STDOUT,
                              start_new_session=True) as process:
            try:
                code = process.wait(timeout=timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                raise RuntimeError(f'{name} interrupted or exceeded {timeout}s; see {log}') from None
    if code:
        raise RuntimeError(f'{name} exited {code}; see {log}')
    # xcodebuild can return zero with an empty filtered suite. Do not cache that as a pass.
    if name == 'tests-diagnostics-configuration':
        text = log.read_text(errors='replace')
        if '** TEST SUCCEEDED **' not in text or not re.search(r'Executed [1-9][0-9]* tests?, with 0 failures', text):
            raise RuntimeError(f'No successful nonempty XCTest run found; see {log}')
    print(f'PASS {name}', flush=True)


def run(options):
    output = OUTPUT / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8])
    plan = commands(options, output)
    if options.dry_run:
        # A preview may first need a Debug build; it never silently runs XCTest.
        if options.mode == 'previews':
            print('If no current Debug build exists: build.sh --unsigned --debug, then verify_configuration.py --app')
        print(json.dumps({'state': str(STATE), 'output': str(output), 'commands': [command for _, command, _ in plan]}, indent=2))
        return 0
    if options.mode == 'previews' and options.target == 'dashboard':
        entry = ROOT / 'Veyra/App/VeyraApp.swift'
        source = entry.read_text() if entry.is_file() else ''
        if not (ROOT / 'Veyra/App/DashboardPreview.swift').is_file() or not all(
                token in source for token in ('--render-dashboard-previews', 'DashboardPreview.render(')):
            raise RuntimeError('Dashboard preview is unavailable in this checkout; use previews menu or settings')
    with lock():
        env = environment()
        source = source_digest()
        toolchain = toolchain_digest(env)
        debug_fingerprint = fingerprint(source, toolchain, 'debug-build')
        release_fingerprint = fingerprint(source, toolchain, 'release-build')
        scope = vars(options).copy()
        scope.pop('force', None)
        scope.pop('dry_run', None)
        expected = fingerprint(source, toolchain, scope)
        stamp = stamp_path(json.dumps(scope, sort_keys=True))
        artifacts = ([app('Debug'), STATE / 'debug/Build/Products/Debug/VeyraTests.xctest'] if options.mode == 'test'
                     else [app('Release')] if options.mode == 'release-build' else [])
        if options.mode == 'previews':
            # Store the output tree and the actual rendered binary as preview evidence.
            try:
                previous = json.loads(stamp.read_text())
                locales = ('en', 'zh') if options.language == 'both' else (options.language,)
                artifacts = [app('Debug')] + [Path(previous['output']) / locale for locale in (locales[:1] if options.native_only else locales)]
            except (OSError, ValueError, KeyError, TypeError):
                artifacts = []
        if options.mode in ('test', 'release-build', 'previews') and not options.force and artifacts:
            record = cached(stamp, expected, artifacts)
            if record:
                print(f'SKIP unchanged {options.mode}: reusing successful evidence at {record["output"]}; use --force to rerun')
                return 0
        if options.mode == 'launch' and not cached(stamp_path('release-build'), release_fingerprint, [app('Release')]):
            raise RuntimeError('Run release-build first; launch requires a current verified Release app')
        output.mkdir(parents=True)
        if options.mode in ('test', 'previews'):
            env['CODEX_HOME'] = str(output / 'fixture-codex-home')
            Path(env['CODEX_HOME']).mkdir()
        elif options.mode == 'launch' and 'CODEX_HOME' in os.environ:
            # Preserve the user's explicit home without forwarding other account variables.
            env['CODEX_HOME'] = os.environ['CODEX_HOME']
        env['VEYRA_DERIVED_DATA_PATH'] = str(STATE / ('release' if options.mode == 'release-build' else 'debug'))
        stamp.unlink(missing_ok=True)
        result = {'scope': scope, 'fingerprint': expected, 'status': 'running'}
        rebuilt_debug = False
        try:
            if options.mode == 'previews' and not cached(stamp_path('debug-build'), debug_fingerprint, [app('Debug')]):
                execute('debug-build', ['/bin/zsh', '-f', str(ROOT / 'scripts/build.sh'), '--unsigned', '--debug'], 900, output, env)
                execute('debug-configuration', [PYTHON, '-I', '-B', str(ROOT / 'scripts/verify_configuration.py'), '--app', str(binary('Debug'))], 60, output, env)
                rebuilt_debug = True
            for name, command, timeout in plan:
                execute(name, command, timeout, output, env)
            if source_digest() != source or toolchain_digest(environment()) != toolchain:
                raise RuntimeError('Inputs changed during verification; result is inconclusive and will not be reused')
            if options.mode == 'previews':
                locales = ('en', 'zh') if options.language == 'both' else (options.language,)
                artifacts = [app('Debug')] + [output / locale for locale in (locales[:1] if options.native_only else locales)]
                for locale in (() if options.native_only else locales):
                    layouts = json.loads((output / locale / 'layouts.json').read_text())
                    if not layouts or not list((output / locale).glob('*.png')):
                        raise RuntimeError(f'Preview evidence is missing for {locale}')
                if options.target == 'menu':
                    for style in ('light', 'dark', 'light-increased', 'dark-increased', 'light-opaque', 'dark-opaque'):
                        records = json.loads((output / locales[0] / ('native-' + style) / 'menu-check.json').read_text())
                        if not any(row.get('toggleAndEscapePassed') is True for row in records):
                            raise RuntimeError(f'Native menu interaction evidence is missing for {style}')
            if options.mode == 'test' or rebuilt_debug:
                save_stamp(stamp_path('debug-build'), debug_fingerprint, [app('Debug')], output)
            if options.mode == 'release-build':
                save_stamp(stamp_path('release-build'), release_fingerprint, [app('Release')], output)
            if options.mode in ('test', 'release-build', 'previews'):
                save_stamp(stamp, expected, artifacts, output)
            result['status'] = 'passed'
        except Exception:
            result['status'] = 'failed'
            raise
        finally:
            (output / 'result.json').write_text(json.dumps(result, indent=2))
        print(f'PASS {options.mode}: {output}')
    return 0


def main():
    try:
        return run(arguments())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'FAIL verification: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
