#!/usr/bin/env python3
"""Validate and install only this repository's fixed verification rules."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'scripts/codex-local-verification.rules'
TARGET = ROOT / '.codex/rules/local-verification.rules'
ENTRY = ['/usr/bin/python3', '-I', '-B', str(ROOT / 'scripts/verify_local.py')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Validate without installing or writing rules')
    options = parser.parse_args()
    codex = shutil.which('codex')
    if codex is None:
        parser.error('codex is required for rule matching checks')
    cases = [
        (ENTRY + ['test'], 'allow'),
        (ENTRY + ['test', '--only-testing', 'VeyraTests/MonitorStoreTests'], 'allow'),
        (ENTRY + ['test', '--only-testing', 'VeyraTests/MonitorStoreTests',
                  '--only-testing', 'VeyraTests/CoreTests'], 'allow'),
        (ENTRY + ['release-build'], 'allow'),
        (ENTRY + ['previews', 'menu'], 'allow'),
        (ENTRY + ['previews', 'settings'], 'allow'),
        (ENTRY + ['launch'], 'prompt'),
        (ENTRY + ['ax-read', '123'], 'prompt'),
        (ENTRY + ['install-rules'], None),
        (['python3', 'scripts/verify_local.py', 'test'], None),
        (['/usr/bin/python3', '-c', 'print(1)'], None),
        (['/bin/zsh', '-lc', 'open /Applications/Veyra.app'], None),
        (['xcodebuild', '-project', 'Veyra.xcodeproj'], None),
        (['/usr/bin/python3', '-I', '-B', '/private/tmp/verify_local.py', 'test'], None),
    ]
    source = SOURCE.read_bytes()
    for command, expected in cases:
        result = subprocess.run([codex, 'execpolicy', 'check', '--rules', str(SOURCE), '--'] + command,
                                capture_output=True, text=True, check=True, timeout=30)
        payload = json.loads(result.stdout)
        if payload.get('decision') != expected:
            raise RuntimeError(f'Unexpected rule decision for {command}: {payload}')
    if SOURCE.read_bytes() != source:
        raise RuntimeError('Rules changed during validation; nothing installed')
    print(f'PASS {len(cases)} rule boundaries')
    if options.check:
        return 0
    if TARGET.is_symlink() or TARGET.parent.is_symlink() or TARGET.parent.parent.is_symlink():
        raise RuntimeError('Refusing to install through a symlink')
    if TARGET.exists() and TARGET.read_bytes() != source:
        raise RuntimeError(f'{TARGET} already has different rules; review it before replacing')
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    if not TARGET.exists():
        # Exclusive creation preserves a concurrent installation or manual change.
        with TARGET.open('xb') as handle:
            handle.write(source)
    if TARGET.read_bytes() != source:
        raise RuntimeError('Installed rule readback differs')
    print(f'Installed: {TARGET}')
    print('Restart Codex to load trusted project rules. Static matching does not establish live approval behavior.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'FAIL rule installation: {error}', file=sys.stderr)
        sys.exit(1)
