#!/bin/bash
# Builds a distributable Sweep release: ad-hoc signed Sweep.app, zipped and in a DMG, with SHA-256 sums.
#
#   scripts/release.sh            -> dist/Sweep-<version>.zip, dist/Sweep-<version>.dmg, dist/SHA256SUMS.txt
#
# Release builds are always ad-hoc signed (App/Local.xcconfig is ignored), so no personal or team
# certificate ends up in a public download, and stripped, so no build paths (home folder) leak either.
# They are not notarized: see "Install a release" in README.md.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' App/project.yml | head -1)
[ -n "$VERSION" ] || { echo "Could not read MARKETING_VERSION from App/project.yml" >&2; exit 1; }

(cd App && xcodegen generate --quiet)
xcodebuild -project App/Sweep.xcodeproj -scheme Sweep -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode-dist \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=non-global COPY_PHASE_STRIP=YES \
  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
  build -quiet

APP=".build/xcode-dist/Build/Products/Release/Sweep.app"
codesign --verify --deep --strict "$APP"
if codesign -dv "$APP" 2>&1 | grep -q '^TeamIdentifier=[A-Z0-9]\{10\}'; then
  echo "Release build is signed with a team; refusing to package it." >&2; exit 1
fi
# Debug symbols carry absolute build paths (and so the builder's home folder). They're stripped above; check.
if grep -rlaF "$HOME" "$APP" >/dev/null; then
  echo "Release build contains $HOME (unstripped debug paths?); refusing to package it:" >&2
  grep -rlaF "$HOME" "$APP" >&2; exit 1
fi

mkdir -p dist
rm -f "dist/Sweep-$VERSION.zip" "dist/Sweep-$VERSION.dmg" dist/SHA256SUMS.txt
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/Sweep-$VERSION.zip"

STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Sweep.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Sweep $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "dist/Sweep-$VERSION.dmg"
rm -rf "$STAGE"

(cd dist && shasum -a 256 "Sweep-$VERSION.zip" "Sweep-$VERSION.dmg" > SHA256SUMS.txt && cat SHA256SUMS.txt)
echo "Built dist/Sweep-$VERSION.zip and dist/Sweep-$VERSION.dmg"
