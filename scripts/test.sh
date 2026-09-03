#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodebuild -project CodexMonitor.xcodeproj -scheme CodexMonitor -configuration Debug -derivedDataPath build -destination 'platform=macOS' test
