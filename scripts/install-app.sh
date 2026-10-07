#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Minimal Bird contributors
set -euo pipefail
cd "$(dirname "$0")/.."
APP_NAME="Minimal Bird.app"
SOURCE_APP="$PWD/build/$APP_NAME"
DESTINATION_DIR="${1:-/Applications}"
TARGET_APP="$DESTINATION_DIR/$APP_NAME"
if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Build the app first: ./scripts/build-app.sh" >&2
  exit 1
fi
if /usr/bin/pgrep -x MinimalBird >/dev/null; then
  echo "Quit Minimal Bird before installing an update; drafts stay protected by the app." >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"
if [[ -L "$TARGET_APP" ]]; then
  echo "The install target is a symbolic link; leaving it alone." >&2
  exit 1
fi
if [[ -e "$TARGET_APP" ]]; then
  EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$TARGET_APP/Contents/Info.plist")
  if [[ "$EXISTING_ID" != "io.github.erik5000.minimalbird" ]]; then
    echo "An unrelated app already exists at $TARGET_APP; leaving it alone." >&2
    exit 1
  fi
fi
mkdir -p "$DESTINATION_DIR"
STAGE_DIR="$(mktemp -d "$DESTINATION_DIR/.minimal-bird-install.XXXXXX")"
cleanup() {
  if [[ -d "$STAGE_DIR/previous.app" && ! -e "$TARGET_APP" ]]; then
    if ! mv "$STAGE_DIR/previous.app" "$TARGET_APP"; then
      echo "Previous app preserved at $STAGE_DIR/previous.app" >&2
      return
    fi
  fi
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT
/usr/bin/ditto "$SOURCE_APP" "$STAGE_DIR/$APP_NAME"
/usr/bin/codesign --verify --deep --strict "$STAGE_DIR/$APP_NAME"
if [[ -e "$TARGET_APP" ]]; then mv "$TARGET_APP" "$STAGE_DIR/previous.app"; fi
mv "$STAGE_DIR/$APP_NAME" "$TARGET_APP"
echo "Installed: $TARGET_APP"
