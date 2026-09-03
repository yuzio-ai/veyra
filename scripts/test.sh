#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodebuild -project Veyra.xcodeproj -scheme Veyra -configuration Debug -derivedDataPath build -destination 'platform=macOS' test
