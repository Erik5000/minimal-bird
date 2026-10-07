#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Min Twitter contributors
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/min-twitter-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/min-twitter-swift-cache"
BUILD_FLAGS=(-c release --disable-sandbox)
if [[ "$#" == 1 && "${1:-}" == "--universal" ]]; then
  BUILD_FLAGS+=(--arch arm64 --arch x86_64)
elif [[ "$#" != 0 ]]; then
  echo "Usage: $0 [--universal]" >&2
  exit 1
fi
swift build "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
mkdir -p "$PWD/build"
OUTPUT_APP="$PWD/build/Min Twitter.app"
STAGE_DIR="$(mktemp -d "$PWD/build/.app-stage.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
APP_DIR="$STAGE_DIR/Min Twitter.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/MinTwitter" "$APP_DIR/Contents/MacOS/MinTwitter"
/usr/bin/strip -S "$APP_DIR/Contents/MacOS/MinTwitter"
cp -R "$BIN_DIR/MinTwitter_MinTwitter.bundle" "$APP_DIR/Contents/Resources/"
cp LICENSE "$APP_DIR/Contents/Resources/LICENSE.txt"
cp NOTICE "$APP_DIR/Contents/Resources/NOTICE.txt"
ICON_SET="$PWD/build/AppIcon.iconset"
swift -module-cache-path "$SWIFTPM_MODULECACHE_OVERRIDE" scripts/make-icon.swift "$ICON_SET"
iconutil -c icns "$ICON_SET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Min Twitter</string>
  <key>CFBundleDisplayName</key><string>Min Twitter</string>
  <key>CFBundleIdentifier</key><string>local.mintwitter.app</string>
  <key>CFBundleExecutable</key><string>MinTwitter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.6.1</string>
  <key>CFBundleVersion</key><string>9</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
SIGNING_IDENTITY="${MIN_TWITTER_SIGNING_IDENTITY:--}"
SIGN_FLAGS=(--force --options runtime --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then SIGN_FLAGS+=(--timestamp); fi
codesign "${SIGN_FLAGS[@]}" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
# Build output is disposable; replace it only after a complete verified bundle
# exists so removed resources cannot survive from an earlier build.
if [[ -e "$OUTPUT_APP" ]]; then
  mv "$OUTPUT_APP" "$STAGE_DIR/previous.app"
fi
if ! mv "$APP_DIR" "$OUTPUT_APP"; then
  if [[ -d "$STAGE_DIR/previous.app" ]]; then mv "$STAGE_DIR/previous.app" "$OUTPUT_APP"; fi
  exit 1
fi
echo "Built: $OUTPUT_APP"
