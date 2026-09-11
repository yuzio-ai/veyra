#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ -n "${VEYRA_DERIVED_DATA_PATH:-}" ]]; then
    derived_data="$VEYRA_DERIVED_DATA_PATH"
elif [[ "$PWD" == "$HOME/Documents/"* || "$PWD" == "$HOME/Desktop/"* || "$PWD" == "$HOME/Downloads/"* ]]; then
    derived_data="$HOME/Library/Developer/Xcode/DerivedData/Veyra"
    print -r -- "test.sh: repository is inside a protected folder; using derived data at $derived_data"
else
    derived_data="$PWD/build"
fi
# Fail here, with a clear cause, instead of inside xcodebuild's arena setup. A
# sandboxed agent session cannot write outside its workspace even when the shell
# user owns the directory, so exists-and-owned is not enough: probe an actual write.
derived_probe="$derived_data/.veyra-write-probe-$$"
if ! mkdir -p "$derived_data" 2>/dev/null || ! { : > "$derived_probe" } 2>/dev/null; then
    print -r -- "test.sh: derived data path is not writable: $derived_data" >&2
    print -r -- "         set VEYRA_DERIVED_DATA_PATH to a writable path, for example:" >&2
    print -r -- "         VEYRA_DERIVED_DATA_PATH=\"\$PWD/build/TestDerivedData\" ./scripts/test.sh" >&2
    exit 1
fi
rm -f "$derived_probe"
xcodebuild -project Veyra.xcodeproj -scheme Veyra -configuration Debug -derivedDataPath "$derived_data" -destination 'platform=macOS' test
python3 scripts/test_diagnostics.py --app "$derived_data/Build/Products/Debug/Veyra.app/Contents/MacOS/Veyra"
# Read-only invariant check for configuration that lives only in the project
# generator and Info.plist, so it has no XCTest coverage of its own.
verify_arguments=(--app "$derived_data/Build/Products/Debug/Veyra.app/Contents/MacOS/Veyra")
if [[ -x "$derived_data/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra" ]]; then
    verify_arguments+=(--derived-data "$derived_data")
fi
python3 scripts/verify_configuration.py "${verify_arguments[@]}"
