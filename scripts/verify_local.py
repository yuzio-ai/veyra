#!/usr/bin/env python3
"""Fixed, unsigned local verification. No shell strings or arbitrary tool arguments."""
import argparse
from contextlib import contextmanager
import ctypes
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
import platform
import plistlib
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
STATE = Path('/private/tmp/veyra-local-verification') / hashlib.sha256(str(ROOT).encode()).hexdigest()[:16]
OUTPUT = ROOT / 'build/local-verification'
PYTHON = '/usr/bin/python3'
SELECTOR = re.compile(r'VeyraTests(?:/[A-Za-z_][A-Za-z0-9_]*){1,2}')


class VerificationInterrupted(BaseException):
    def __init__(self, signum):
        self.signum = signum


@contextmanager
def handle_interruptions():
    interrupted = False
    def interrupt(signum, frame):
        nonlocal interrupted
        if not interrupted:
            interrupted = True
            raise VerificationInterrupted(signum)
    previous = {signum: signal.signal(signum, interrupt) for signum in (signal.SIGINT, signal.SIGTERM)}
    try:
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


@contextmanager
def finish_worker_cleanup():
    # A first signal during timeout cleanup must not release the lock early either.
    previous = {signum: signal.signal(signum, signal.SIG_IGN) for signum in (signal.SIGINT, signal.SIGTERM)}
    try:
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


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
            child.add_argument('target', choices=('menu', 'settings'))
            child.add_argument('--language', choices=('en', 'zh', 'both'), default='both')
            child.add_argument('--native-only', action='store_true', help='Run only the six fixed fixture popover checks (menu only)')
            child.add_argument('--dsh-only', action='store_true', help='Render only dsh capability fixtures and native menu checks (menu only)')
        if mode == 'launch':
            child.add_argument('--language', choices=('en', 'zh'), default='zh')
        if mode == 'ax-read':
            child.add_argument('pid', type=int)
    result = parser.parse_args(argv)
    if getattr(result, 'only_testing', None) and not SELECTOR.fullmatch(result.only_testing):
        parser.error('--only-testing must be VeyraTests/TestClass[/testMethod]')
    if result.mode == 'previews' and result.dsh_only and (result.target != 'menu' or result.native_only):
        parser.error('--dsh-only requires previews menu and cannot be combined with --native-only')
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


def focus_host_app():
    return STATE / 'focus-host/Veyra Keyboard Fixture.app'


def prepare_focus_host_app():
    destination = focus_host_app()
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['/usr/bin/ditto', str(app('Debug')), str(destination)], check=True, timeout=60)
    info = destination / 'Contents/Info.plist'
    data = plistlib.loads(info.read_bytes())
    data['CFBundleIdentifier'] += '.keyboard-focus-host'
    data['CFBundleName'] = 'Veyra Keyboard Fixture'
    data['CFBundleDisplayName'] = 'Veyra Keyboard Fixture'
    data['LSUIElement'] = False
    info.write_bytes(plistlib.dumps(data))


def language(locale):
    return ['-AppleLanguages', '(en)' if locale == 'en' else '("zh-Hans")',
            '-AppleLocale', 'en_US' if locale == 'en' else 'zh_CN']


def gui_preview_command(arguments, name, output):
    return ['/usr/bin/open', '-n', '-W', '-a', str(app('Debug')),
            '--stdout', str(output / (name + '.app.log')),
            '--stderr', str(output / (name + '.app.stderr.log')),
            '--env', 'CODEX_HOME=' + str(output / 'fixture-codex-home'),
            '--args'] + arguments + ['--preview-lease', str(uuid.uuid4())]


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
        extra = ['--preview-settings-only'] if options.target == 'settings' else (['--preview-dsh-only', '--exercise-settings'] if options.dsh_only else [])
        plan = [('previews-' + locale, gui_preview_command(
                    ['--render-previews', str(output / locale)] + extra + language(locale), 'previews-' + locale, output), 300)
                for locale in locales]
        if options.native_only:
            plan = []
        if options.target == 'menu':
            # Fixed fixture popovers only: no live launch, real Codex home, global hotkey, or network.
            for style in ('light', 'dark', 'light-increased', 'dark-increased', 'light-opaque', 'dark-opaque'):
                appearance = style.removesuffix('-opaque')
                command = gui_preview_command(['--preview-menu', 'multiple', '--show-menu',
                           '--preview-appearance', appearance, '--exercise-menu-to', str(output / locales[0] / ('native-' + style)),
                           '--exit-after-menu-checks'] + language(locales[0]), 'native-menu-' + style, output)
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


def preview_fixture(command):
    if command[0] != '/usr/bin/open' or '--preview-lease' not in command:
        return None
    target = ('--preview-focus-host' if '--preview-focus-host' in command else
              '--exercise-menu-to' if '--exercise-menu-to' in command else '--render-previews')
    directory = Path(command[command.index(target) + 1])
    token = command[command.index('--preview-lease') + 1]
    uuid.UUID(token)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'active-lease').write_text(token)
    executable = (Path(command[command.index('-a') + 1]) / 'Contents/MacOS/Veyra') if '-a' in command else binary('Debug')
    return directory, executable.resolve(), token


def executable_path(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib')
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    if library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        return None
    return Path(os.fsdecode(buffer.value)).resolve()


def stop_preview_fixture(directory, executable, token):
    # Revoke before reading the receipt. A delayed LaunchServices instance writes
    # its receipt before checking this lease, so it cannot start UI after cleanup.
    (directory / 'active-lease').unlink(missing_ok=True)
    receipt = directory / 'process.json'
    if not receipt.exists():
        return
    data = json.loads(receipt.read_text())
    pid = data.get('pid')
    if type(pid) is not int or pid <= 1 or data.get('group') != pid or data.get('token') != token:
        raise RuntimeError('Native fixture process receipt is invalid; refusing to signal it')
    try:
        group = os.getpgid(pid)
    except ProcessLookupError:
        return
    if group != pid or executable_path(pid) != executable:
        raise RuntimeError('Native fixture process identity changed; refusing to signal it')
    arguments = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'args='],
                               capture_output=True, text=True, timeout=5).stdout
    words = arguments.split()
    if '--preview-lease' not in words or words[words.index('--preview-lease') + 1:][:1] != [token]:
        # Revoking a lease can make the app exit between identity lookup and ps.
        # Accept only a proven exit; a live process with different arguments is
        # still refused, including a PID reused during this check.
        try:
            os.getpgid(pid)
        except ProcessLookupError:
            return
        raise RuntimeError('Native fixture launch token changed; refusing to signal it')
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    # LaunchServices owns this process, so waitpid cannot reap it here.
    deadline = time.monotonic() + 5
    while executable_path(pid) == executable:
        if time.monotonic() >= deadline:
            raise RuntimeError('Native fixture did not terminate after cleanup')
        time.sleep(0.02)


def execute(name, command, timeout, output, env):
    log = output / (name + '.log')
    print(f'RUN {name}: {log}', flush=True)
    fixture = preview_fixture(command)
    host_fixture = None
    host_process = None
    with log.open('wb') as handle:
        try:
            if fixture and '--exercise-menu-to' in command and '-a' in command:
                directory, _, token = fixture
                host_command = ['/usr/bin/open', '-n', '-W', '-a', str(focus_host_app()),
                    '--stdout', str(output / (name + '.focus-host.log')),
                    '--stderr', str(output / (name + '.focus-host.stderr.log')),
                    '--args', '--preview-focus-host', str(directory / 'focus-host'), '--preview-lease', token]
                host_fixture = preview_fixture(host_command)
                host_process = subprocess.Popen(host_command, cwd=ROOT, env=env, stdout=handle, stderr=subprocess.STDOUT,
                                                start_new_session=True)
                # Serialize LaunchServices activation. Starting both apps at once
                # can leave neither active and isn't a valid background-open test.
                deadline = time.monotonic() + 5
                ready = directory / 'focus-host/host-ready'
                while not ready.exists() or ready.read_text() != token:
                    if host_process.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError('Keyboard focus host did not become active')
                    time.sleep(0.02)
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=handle, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                code = process.wait(timeout=timeout)
            except BaseException as error:
                # The opener and its LaunchServices app have different process groups.
                with finish_worker_cleanup():
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=5)
                if isinstance(error, subprocess.TimeoutExpired):
                    raise RuntimeError(f'{name} interrupted or exceeded {timeout}s; see {log}') from None
                raise
        finally:
            if fixture:
                with finish_worker_cleanup():
                    try:
                        stop_preview_fixture(*fixture)
                    finally:
                        if host_fixture:
                            stop_preview_fixture(*host_fixture)
                        if host_process and host_process.poll() is None:
                            try:
                                os.killpg(host_process.pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                            host_process.wait(timeout=5)
                for suffix in ('.app.log', '.app.stderr.log'):
                    app_log = output / (name + suffix)
                    if app_log.exists():
                        handle.write(app_log.read_bytes())
    if code:
        raise RuntimeError(f'{name} exited {code}; see {log}')
    result_name = 'menu-check.json' if '--exercise-menu-to' in command else 'layouts.json'
    if fixture and not (fixture[0] / result_name).exists():
        # open -W returns its own status, not the app's exit status.
        raise RuntimeError(f'{name} produced no successful GUI preview result; see {log}')
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
    with handle_interruptions(), lock():
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
            if options.mode == 'previews' and options.target == 'menu':
                prepare_focus_host_app()
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
                    if options.dsh_only:
                        required = {'dsh-only-light', 'dsh-idle-light', 'dsh-unknown-light', 'dsh-error-light',
                                    'no-sources-light', 'mixed-error-light', 'settings-missing-light', 'settings-dsh-models-light'}
                        if not required.issubset({row.get('name') for row in layouts}):
                            raise RuntimeError(f'dsh capability preview evidence is missing for {locale}')
                        settings = json.loads((output / locale / 'settings-native-checks.json').read_text())
                        if not {'dsh-path-commit', 'dsh-invalid-draft', 'dsh-close-and-reopen', 'dsh-restore'}.issubset(settings.get('passed', [])):
                            raise RuntimeError(f'Native dsh settings evidence is missing for {locale}')
                if options.target == 'menu':
                    for style in ('light', 'dark', 'light-increased', 'dark-increased', 'light-opaque', 'dark-opaque'):
                        records = json.loads((output / locales[0] / ('native-' + style) / 'menu-check.json').read_text())
                        if not any(row.get('toggleAndEscapePassed') is True and row.get('appWasActive') is True
                                   and row.get('windowWasKey') is True and row.get('openedFromBackground') is True
                                   and row.get('previousApplicationRestored') is True for row in records):
                            raise RuntimeError(f'Native menu interaction evidence is missing for {style}')
                        if not any(row.get('position') == 'dsh-only'
                                and row.get('providerHidden') is True and row.get('quotaHidden') is True
                                and row.get('escapePassed') is True and row.get('appWasActive') is True
                                and row.get('windowWasKey') is True and row.get('openedFromBackground') is True
                                and row.get('previousApplicationRestored') is True for row in records):
                            raise RuntimeError(f'Native dsh interaction evidence is missing for {style}')
            if options.mode == 'test' or rebuilt_debug:
                save_stamp(stamp_path('debug-build'), debug_fingerprint, [app('Debug')], output)
            if options.mode == 'release-build':
                save_stamp(stamp_path('release-build'), release_fingerprint, [app('Release')], output)
            if options.mode in ('test', 'release-build', 'previews'):
                save_stamp(stamp, expected, artifacts, output)
            result['status'] = 'passed'
        except BaseException:
            result['status'] = 'failed'
            raise
        finally:
            (output / 'result.json').write_text(json.dumps(result, indent=2))
        print(f'PASS {options.mode}: {output}')
    return 0


def main():
    try:
        return run(arguments())
    except VerificationInterrupted as error:
        print(f'FAIL verification: interrupted by signal {error.signum}', file=sys.stderr)
        return 128 + error.signum
    except KeyboardInterrupt:
        print('FAIL verification: interrupted', file=sys.stderr)
        return 130
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'FAIL verification: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
