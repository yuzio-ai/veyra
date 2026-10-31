#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
build_arguments=()
while (( $# )); do
    case "$1" in
        --unsigned) build_arguments+=(CODE_SIGNING_ALLOWED=NO); shift ;;
        --only-testing)
            if (( $# < 2 )) || [[ ! "$2" =~ '^VeyraTests(/[A-Za-z_][A-Za-z0-9_]*){1,2}$' ]]; then
                print -r -- 'test.sh: expected VeyraTests/TestClass[/testMethod]' >&2
                exit 2
            fi
            build_arguments+=("-only-testing:$2"); shift 2 ;;
        *) print -r -- "test.sh: unsupported argument: $1" >&2; exit 2 ;;
    esac
done
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
xcodebuild -project Veyra.xcodeproj -scheme Veyra -configuration Debug -derivedDataPath "$derived_data" -destination 'platform=macOS' "${build_arguments[@]}" test
python3 scripts/test_diagnostics.py --app "$derived_data/Build/Products/Debug/Veyra.app/Contents/MacOS/Veyra"
python3 -I -B scripts/test_local_verification.py
python3 -I -B scripts/test_measure_energy.py
# Read-only invariant check for project configuration and packaging, which has
# no XCTest coverage of its own.
verify_arguments=(--app "$derived_data/Build/Products/Debug/Veyra.app/Contents/MacOS/Veyra")
if [[ -x "$derived_data/Build/Products/Release/Veyra.app/Contents/MacOS/Veyra" ]]; then
    verify_arguments+=(--derived-data "$derived_data")
fi
python3 scripts/verify_configuration.py "${verify_arguments[@]}"
