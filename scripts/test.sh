#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
derived_data="${VEYRA_DERIVED_DATA_PATH:-$PWD/build}"
xcodebuild -project Veyra.xcodeproj -scheme Veyra -configuration Debug -derivedDataPath "$derived_data" -destination 'platform=macOS' test
python3 scripts/test_diagnostics.py --app "$derived_data/Build/Products/Debug/Veyra.app/Contents/MacOS/Veyra"
