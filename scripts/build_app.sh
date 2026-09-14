#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/TokenBar.app"
STAGING_DIR=""

cleanup() {
    if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
        rm -rf -- "$STAGING_DIR"
    fi
}
trap cleanup EXIT

cd "$PROJECT_DIR"
# No package plugins or external dependencies are used; disabling SwiftPM's
# nested sandbox also lets this script run inside restricted build runners.
swift build --disable-sandbox -c release
BIN_DIR="$(swift build --disable-sandbox -c release --show-bin-path)"

mkdir -p "$DIST_DIR"
STAGING_DIR="$(mktemp -d "$DIST_DIR/.TokenBar.XXXXXX")"
STAGED_APP="$STAGING_DIR/TokenBar.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

cp "$BIN_DIR/TokenBar" "$STAGED_APP/Contents/MacOS/TokenBar"
cp "$PROJECT_DIR/Supporting/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_DIR/Sources/TokenBar/Resources/claude-icon.svg" "$STAGED_APP/Contents/Resources/"
cp "$PROJECT_DIR/Sources/TokenBar/Resources/openAI-icon.svg" "$STAGED_APP/Contents/Resources/"
cp "$PROJECT_DIR/Sources/TokenBar/Resources/gemini-icon.svg" "$STAGED_APP/Contents/Resources/"

SIGNING_IDENTITY="${TOKENBAR_CODESIGN_IDENTITY:--}"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$STAGED_APP"

if [[ "$APP_DIR" != "$PROJECT_DIR/dist/TokenBar.app" ]]; then
    echo "Refusing to replace an unexpected app path" >&2
    exit 1
fi
rm -rf -- "$APP_DIR"
mv "$STAGED_APP" "$APP_DIR"

echo "Created $APP_DIR"
