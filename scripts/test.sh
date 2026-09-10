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
xcodebuild -project Veyra.xcodeproj -scheme Veyra -configuration Debug -derivedDataPath "$derived_data" -destination 'platform=macOS' test
python3 scripts/test_diagnostics.py --app "$derived_data/Build/Products/Debug/Veyra.app/Contents/MacOS/Veyra"
