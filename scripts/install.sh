#!/bin/bash
# Builds Sweep (Release) and installs it to /Applications/Sweep.app, replacing an older copy.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$(scripts/build-app.sh | tail -1)"
DEST="/Applications/Sweep.app"
if pgrep -x Sweep >/dev/null; then
  echo "Quitting the running Sweep…"
  osascript -e 'tell application id "dev.algamthe.sweep" to quit' || true
  sleep 2
fi
if [ -d "$DEST" ]; then
  echo "Replacing $DEST"
  rm -rf "/Applications/Sweep.app"
fi
ditto "$APP" "$DEST"
codesign --verify --deep --strict "$DEST"
echo "Installed $DEST ($(defaults read "$DEST/Contents/Info" CFBundleShortVersionString))"
echo "Open it with: open -a Sweep"
