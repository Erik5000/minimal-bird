#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Minimal Bird contributors
set -euo pipefail
cd "$(dirname "$0")/.."
NOTARIZE=false
if [[ "$#" == 1 && "$1" == "--notarize" ]]; then
  NOTARIZE=true
  : "${MINIMAL_BIRD_SIGNING_IDENTITY:?Set a Developer ID Application signing identity}"
  : "${MINIMAL_BIRD_NOTARY_PROFILE:?Set a stored notarytool keychain profile}"
  if [[ "$MINIMAL_BIRD_SIGNING_IDENTITY" == "-" ]]; then
    echo "Notarized releases require Developer ID signing." >&2; exit 1
  fi
elif [[ "$#" != 0 ]]; then
  echo "Usage: $0 [--notarize]" >&2; exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit source changes before packaging a release." >&2
  exit 1
fi
SOURCE_COMMIT="$(git rev-parse HEAD)"
./scripts/build-app.sh --universal
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/minimal-bird-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/minimal-bird-swift-cache"
swift test --disable-sandbox
"build/Minimal Bird.app/Contents/MacOS/MinimalBird" --self-test
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "build/Minimal Bird.app/Contents/Info.plist")
RELEASE_DIR="$PWD/build/releases"
mkdir -p "$RELEASE_DIR"
STAGE_DIR="$(mktemp -d "$PWD/build/.release-stage.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
SUFFIX=macos-local
if $NOTARIZE; then SUFFIX=macos; fi
APP_ZIP="$STAGE_DIR/minimal-bird-$VERSION-$SUFFIX.zip"
SOURCE_ZIP="$STAGE_DIR/minimal-bird-$VERSION-source.zip"
/usr/bin/codesign --verify --deep --strict "build/Minimal Bird.app"
/usr/bin/ditto -c -k --keepParent --norsrc "build/Minimal Bird.app" "$APP_ZIP"
if $NOTARIZE; then
  if ! /usr/bin/codesign -dvv "build/Minimal Bird.app" 2>&1 | /usr/bin/grep -q '^Authority=Developer ID Application:'; then
    echo "The app is not signed with a Developer ID Application certificate." >&2; exit 1
  fi
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$MINIMAL_BIRD_NOTARY_PROFILE" --wait --output-format json > build/notarization-result.json
  if [[ "$(/usr/bin/plutil -extract status raw build/notarization-result.json)" != "Accepted" ]]; then
    echo "Notarization was not accepted. Inspect build/notarization-result.json." >&2; exit 1
  fi
  xcrun stapler staple "build/Minimal Bird.app"
  xcrun stapler validate "build/Minimal Bird.app"
  /usr/sbin/spctl --assess --type execute --verbose "build/Minimal Bird.app"
  /usr/bin/ditto -c -k --keepParent --norsrc "build/Minimal Bird.app" "$APP_ZIP"
fi
if [[ -n "$(git status --porcelain)" || "$(git rev-parse HEAD)" != "$SOURCE_COMMIT" ]]; then
  echo "Source changed during the release build; package it again." >&2; exit 1
fi
git archive --format=zip --prefix="minimal-bird-$VERSION/" "$SOURCE_COMMIT" -o "$SOURCE_ZIP"
cd "$STAGE_DIR"
/usr/bin/shasum -a 256 "$(basename "$APP_ZIP")" "$(basename "$SOURCE_ZIP")" > SHA256SUMS
mv "$APP_ZIP" "$SOURCE_ZIP" SHA256SUMS "$RELEASE_DIR/"
echo "Release packages: $RELEASE_DIR"
if $NOTARIZE; then echo "Developer ID signed, notarized, and stapled."
else echo "Experimental ad-hoc package, not notarized. Share only with this limitation and its matching source clearly stated."; fi
