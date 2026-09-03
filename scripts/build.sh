#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodebuild -project Veyra.xcodeproj -scheme Veyra -configuration Release -derivedDataPath build build
print -r -- "App: $PWD/build/Build/Products/Release/Veyra.app"
