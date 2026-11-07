#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration=Release
build_arguments=()
while (( $# )); do
    case "$1" in
        --unsigned) build_arguments+=(CODE_SIGNING_ALLOWED=NO); shift ;;
        --debug) configuration=Debug; shift ;;
        *) print -r -- "build.sh: unsupported argument: $1" >&2; exit 2 ;;
    esac
done
derived_data="${VEYRA_DERIVED_DATA_PATH:-$PWD/build}"
# Xcode registers build products as launchable apps. Retire the entry on success or failure.
trap '/usr/bin/python3 -I -B "$PWD/scripts/cleanup_app_copies.py" unregister "$derived_data/Build/Products/$configuration/Veyra.app" || exit 1' EXIT
xcodebuild -project Veyra.xcodeproj -scheme Veyra -configuration "$configuration" -derivedDataPath "$derived_data" "${build_arguments[@]}" build
print -r -- "App: $derived_data/Build/Products/$configuration/Veyra.app"
