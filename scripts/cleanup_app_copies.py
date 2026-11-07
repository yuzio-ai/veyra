#!/usr/bin/env python3
"""Remove disposable Veyra bundles and retire their LaunchServices registrations."""
import argparse
from contextlib import ExitStack, contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parent.parent
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
IDENTIFIERS = {'ai.yuzio.veyra', 'com.yuzio.veyra',
               'ai.yuzio.veyra.keyboard-focus-host', 'ai.yuzio.veyra.website-capture'}
NAMES = {'Veyra.app', 'Veyra Keyboard Fixture.app', 'VeyraCapture.app', 'VeyraFake.app'}
TEMP_STATES = Path('/private/tmp/veyra-local-verification')


def installed(path):
    directories = {Path('/Applications').resolve(), (Path.home() / 'Applications').resolve()}
    return path.parent.resolve() in directories or path.resolve().parent in directories


def archive(path):
    return any(part.endswith('.xcarchive') for part in path.parts)


def bundle_identity(path):
    try:
        return plistlib.loads((path / 'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier')
    except FileNotFoundError:
        return None


def registered_apps():
    result = subprocess.run([LSREGISTER, '-dump'], capture_output=True, text=True, check=True, timeout=30)
    if 'bundle id:' not in result.stdout:
        raise RuntimeError('LaunchServices database is unavailable; run cleanup outside the file sandbox')
    paths = set()
    for section in result.stdout.split('--------------------------------------------------------------------------------'):
        fields = dict(re.findall(r'^\s*(path|identifier):\s+([^\n]+)', section, re.MULTILINE))
        if fields.get('identifier') in IDENTIFIERS and 'path' in fields:
            paths.add(Path(re.sub(r' \(0x[0-9a-f]+\)$', '', fields['path'])))
    return paths


def local_apps():
    paths = {ROOT / 'Veyra.app'} if (ROOT / 'Veyra.app').exists() else set()
    for root in (ROOT / 'build', TEMP_STATES):
        for base, directories, _ in os.walk(root, followlinks=False):
            paths.update(Path(base) / name for name in directories if name in NAMES)
            directories[:] = [name for name in directories if not name.endswith(('.app', '.xcarchive', '.xcresult'))
                              and not (Path(base) / name).is_symlink()]
    return paths


def state_directory(path):
    if path.is_relative_to(TEMP_STATES):
        relative = path.relative_to(TEMP_STATES)
        if len(relative.parts) > 1 and re.fullmatch(r'[0-9a-f]{16}', relative.parts[0]):
            return TEMP_STATES / relative.parts[0]
    return None


def disposable(path):
    if path.name not in NAMES or installed(path) or archive(path):
        return False
    if path == ROOT / 'Veyra.app' or path.is_relative_to(ROOT / 'build'):
        return True
    if path == Path('/private/tmp/VeyraFake.app'):
        return True
    if path.is_relative_to(Path('/private/tmp')):
        parts = path.relative_to(Path('/private/tmp')).parts
        if len(parts) > 2 and re.fullmatch(r'veyra-website-v[0-9.]+', parts[0]) and parts[1] == 'build':
            return True
    state = state_directory(path)
    if state and path.relative_to(state).parts[0] in {'debug', 'release', 'focus-host'}:
        return True
    # Legacy screenshot worktrees: only their build products, never source or task state.
    worktrees = Path.home() / '.codex/worktrees'
    if path.is_relative_to(worktrees):
        parts = path.relative_to(worktrees).parts
        return len(parts) > 3 and parts[1:3] == ('veyra', 'build')
    derived = Path.home() / 'Library/Developer/Xcode/DerivedData'
    if path.is_relative_to(derived):
        parts = path.relative_to(derived).parts
        return len(parts) > 2 and parts[0].startswith('Veyra') and parts[1] == 'Build'
    return False


def running_executables():
    result = subprocess.run(['/bin/ps', '-axo', 'comm='], capture_output=True, text=True, check=True, timeout=10)
    # Refuse a destructive sweep while Xcode is producing bundles.
    if any(Path(line.strip()).name == 'xcodebuild' for line in result.stdout.splitlines()):
        raise RuntimeError('xcodebuild is running; retry cleanup after builds finish')
    return [Path(line.strip()) for line in result.stdout.splitlines() if line.strip().startswith('/')]


def unregister(path):
    result = subprocess.run([LSREGISTER, '-u', str(path)], capture_output=True, text=True, timeout=15)
    if result.returncode:
        # lsregister can retire the entry and then return a Spotlight scan error
        # (-10814). Accept only a read-back proving the exact entry is gone.
        if path not in registered_apps():
            return
        detail = (result.stderr + result.stdout).strip()
        raise RuntimeError(f'Unable to unregister {path}: {detail or result.returncode}')


def unregister_bundles(paths, include_archives=False):
    targets = {Path(path).absolute() for path in paths}
    registered = None
    if include_archives:
        targets.update(path for path in registered_apps() if archive(path))
    for path in sorted(targets):
        if installed(path):
            continue
        identity = bundle_identity(path)
        if identity in IDENTIFIERS:
            unregister(path)
        elif identity is None:
            if registered is None:
                registered = registered_apps()
            if path in registered:
                unregister(path)


@contextmanager
def state_lock(path):
    # Use the same lock as verify_local.py. Do not remove directories or cache stamps.
    with (path / 'verification.lock').open('a') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def cleanup(apply=False):
    registered = registered_apps()
    candidates = registered | local_apps()
    processes = running_executables() if apply else []
    actions = []
    # Serialize sweeps independently of a verifier's per-checkout lock.
    with ExitStack() as stack:
        if apply:
            sweep_lock = stack.enter_context(state_lock(ROOT / 'build'))
            if not sweep_lock:
                raise RuntimeError('Another app cleanup is running')
        locks = {}
        # Also lock this checkout before deleting historical build/ bundles.
        current_state = TEMP_STATES / hashlib.sha256(str(ROOT).encode()).hexdigest()[:16]
        states = {state_directory(path) for path in candidates} - {None}
        if current_state.exists():
            states.add(current_state)
        for state in sorted(states):
            if apply and state.exists():
                locks[state] = stack.enter_context(state_lock(state))
        report = None
        if apply:
            directory = ROOT / 'build/app-cleanup'
            directory.mkdir(parents=True, exist_ok=True)
            report = directory / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8] + '.json')
            print(f'Report: {report}', flush=True)
        for path in sorted(candidates):
            action = 'keep-other'
            if installed(path):
                action = 'keep-installed'
            elif any(executable.is_relative_to(path) for executable in processes):
                action = 'skip-running'
            elif path != path.resolve():
                action = 'skip-symlink'
            elif (locks.get(state_directory(path)) is False
                  or ((path == ROOT / 'Veyra.app' or path.is_relative_to(ROOT / 'build'))
                      and locks.get(current_state) is False)):
                action = 'skip-busy'
            elif not path.exists():
                action = 'unregister-missing' if path in registered else 'keep-other'
            elif archive(path):
                action = 'unregister-archive' if path in registered else 'keep-archive'
            elif disposable(path):
                identity = bundle_identity(path)
                # An interrupted build may leave an empty bundle. Only its exact,
                # previously registered Veyra identity can authorize deleting it.
                if identity in IDENTIFIERS or (identity is None and path in registered):
                    action = 'remove-bundle'
            row = {'path': str(path), 'action': action}
            actions.append(row)
            if apply:
                # Persist progress before each mutation, including failures or interruption.
                row['applied'] = False
                report.write_text(json.dumps(actions, indent=2) + '\n')
                if action.startswith('unregister-'):
                    unregister(path)
                elif action == 'remove-bundle':
                    # Unregister while the bundle still exists, then remove only this bundle.
                    unregister(path)
                    shutil.rmtree(path)
                row['applied'] = True
                report.write_text(json.dumps(actions, indent=2) + '\n')
        if apply and not actions:
            report.write_text('[]\n')
    return actions


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    modes = parser.add_subparsers(dest='mode', required=True)
    clean = modes.add_parser('clean', allow_abbrev=False)
    clean.add_argument('--apply', action='store_true', help='Apply the plan; otherwise only print it')
    retire = modes.add_parser('unregister', allow_abbrev=False)
    retire.add_argument('--archives', action='store_true', help='Also retire Veyra archive registrations, retaining files')
    retire.add_argument('paths', nargs='+')
    options = parser.parse_args()
    try:
        if options.mode == 'unregister':
            unregister_bundles(options.paths, options.archives)
        else:
            if options.apply:
                (ROOT / 'build').mkdir(parents=True, exist_ok=True)
            actions = cleanup(options.apply)
            counts = {}
            for row in actions:
                counts[row['action']] = counts.get(row['action'], 0) + 1
            print(json.dumps({'applied': options.apply, 'counts': counts, 'actions': actions}, indent=2))
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'FAIL app cleanup: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
