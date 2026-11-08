#!/bin/bash
# Regenerates docs/screenshots from the Debug build's demo mode (made-up data; never your disk).
set -euo pipefail
cd "$(dirname "$0")/.."
(cd App && xcodegen generate --quiet)
xcodebuild -project App/Sweep.xcodeproj -scheme Sweep -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build -quiet
BIN=".build/xcode/Build/Products/Debug/Sweep.app/Contents/MacOS/Sweep"
OUT="$(mktemp -d)"
for mode in light dark; do
  SWEEP_DEMO=1 SWEEP_APPEARANCE="$mode" SWEEP_SNAPSHOT="$OUT/shot" "$BIN" >/dev/null 2>&1 &
  PID=$!
  for _ in $(seq 1 60); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
  kill "$PID" 2>/dev/null || true
done
mkdir -p docs/screenshots
for f in dashboard dashboard-bottom detail plan verify settings-insights settings-maintenance \
         dashboard-dark dashboard-bottom-dark plan-dark verify-dark detail-dark; do
  cp "$OUT/shot-$f.png" "docs/screenshots/$f.png"
done
echo "Updated docs/screenshots"
