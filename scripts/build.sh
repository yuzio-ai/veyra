#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodebuild -project CodexMonitor.xcodeproj -scheme CodexMonitor -configuration Release -derivedDataPath build build
print -r -- "App: $PWD/build/Build/Products/Release/Codex Monitor.app"
