#!/bin/bash
# Builds Sweep.app (Release) into .build/xcode-release and prints its path.
# Signing: ad-hoc by default; put your team in App/Local.xcconfig (see App/Signing.xcconfig).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
(cd App && xcodegen generate --quiet)
xcodebuild -project App/Sweep.xcodeproj -scheme Sweep -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode-release build -quiet
APP="$PWD/.build/xcode-release/Build/Products/Release/Sweep.app"
codesign --verify --deep --strict "$APP"
echo "$APP"
