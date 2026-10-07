#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Min Twitter contributors
set -euo pipefail
cd "$(dirname "$0")/.."
NOTARIZE=false
if [[ "$#" == 1 && "$1" == "--notarize" ]]; then
  NOTARIZE=true
  : "${MIN_TWITTER_SIGNING_IDENTITY:?Set a Developer ID Application signing identity}"
  : "${MIN_TWITTER_NOTARY_PROFILE:?Set a stored notarytool keychain profile}"
  if [[ "$MIN_TWITTER_SIGNING_IDENTITY" == "-" ]]; then
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
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/min-twitter-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/min-twitter-swift-cache"
swift test --disable-sandbox
"build/Min Twitter.app/Contents/MacOS/MinTwitter" --self-test
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "build/Min Twitter.app/Contents/Info.plist")
RELEASE_DIR="$PWD/build/releases"
mkdir -p "$RELEASE_DIR"
STAGE_DIR="$(mktemp -d "$PWD/build/.release-stage.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
SUFFIX=macos-local
if $NOTARIZE; then SUFFIX=macos; fi
APP_ZIP="$STAGE_DIR/min-twitter-$VERSION-$SUFFIX.zip"
SOURCE_ZIP="$STAGE_DIR/min-twitter-$VERSION-source.zip"
/usr/bin/codesign --verify --deep --strict "build/Min Twitter.app"
/usr/bin/ditto -c -k --keepParent --norsrc "build/Min Twitter.app" "$APP_ZIP"
if $NOTARIZE; then
  if ! /usr/bin/codesign -dvv "build/Min Twitter.app" 2>&1 | /usr/bin/grep -q '^Authority=Developer ID Application:'; then
    echo "The app is not signed with a Developer ID Application certificate." >&2; exit 1
  fi
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$MIN_TWITTER_NOTARY_PROFILE" --wait --output-format json > build/notarization-result.json
  if [[ "$(/usr/bin/plutil -extract status raw build/notarization-result.json)" != "Accepted" ]]; then
    echo "Notarization was not accepted. Inspect build/notarization-result.json." >&2; exit 1
  fi
  xcrun stapler staple "build/Min Twitter.app"
  xcrun stapler validate "build/Min Twitter.app"
  /usr/sbin/spctl --assess --type execute --verbose "build/Min Twitter.app"
  /usr/bin/ditto -c -k --keepParent --norsrc "build/Min Twitter.app" "$APP_ZIP"
fi
if [[ -n "$(git status --porcelain)" || "$(git rev-parse HEAD)" != "$SOURCE_COMMIT" ]]; then
  echo "Source changed during the release build; package it again." >&2; exit 1
fi
git archive --format=zip --prefix="min-twitter-$VERSION/" "$SOURCE_COMMIT" -o "$SOURCE_ZIP"
cd "$STAGE_DIR"
/usr/bin/shasum -a 256 "$(basename "$APP_ZIP")" "$(basename "$SOURCE_ZIP")" > SHA256SUMS
mv "$APP_ZIP" "$SOURCE_ZIP" SHA256SUMS "$RELEASE_DIR/"
echo "Release packages: $RELEASE_DIR"
if $NOTARIZE; then echo "Developer ID signed, notarized, and stapled."
else echo "Experimental ad-hoc package, not notarized. Share only with this limitation and its matching source clearly stated."; fi
