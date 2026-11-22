#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/TokenCounter.app"
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
# Universal binary (Apple Silicon + Intel) by default so the .app can be shared
# with any Mac on macOS 13+. Override with e.g. TOKENCOUNTER_ARCHS="arm64".
read -r -a ARCHS <<< "${TOKENCOUNTER_ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for arch in "${ARCHS[@]}"; do ARCH_FLAGS+=(--arch "$arch"); done
swift build --disable-sandbox -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build --disable-sandbox -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

mkdir -p "$DIST_DIR"
STAGING_DIR="$(mktemp -d "$DIST_DIR/.TokenCounter.XXXXXX")"
STAGED_APP="$STAGING_DIR/TokenCounter.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

cp "$BIN_DIR/TokenCounter" "$STAGED_APP/Contents/MacOS/TokenCounter"
cp "$PROJECT_DIR/Supporting/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_DIR/Sources/TokenCounter/Resources/claude-icon.svg" "$STAGED_APP/Contents/Resources/"
cp "$PROJECT_DIR/Sources/TokenCounter/Resources/openAI-icon.svg" "$STAGED_APP/Contents/Resources/"
cp "$PROJECT_DIR/Sources/TokenCounter/Resources/gemini-icon.svg" "$STAGED_APP/Contents/Resources/"
cp "$PROJECT_DIR/Supporting/AppIcon.icns" "$STAGED_APP/Contents/Resources/"
if [[ -d "$BIN_DIR/TokenCounter_TokenCounter.bundle" ]]; then
    cp -R "$BIN_DIR/TokenCounter_TokenCounter.bundle" "$STAGED_APP/Contents/Resources/"
fi

SIGNING_IDENTITY="${TOKENCOUNTER_CODESIGN_IDENTITY:--}"
# Strip extended attributes (e.g. added by iCloud/Finder) that break signing.
xattr -cr "$STAGED_APP"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$STAGED_APP"

if [[ "$APP_DIR" != "$PROJECT_DIR/dist/TokenCounter.app" ]]; then
    echo "Refusing to replace an unexpected app path" >&2
    exit 1
fi
rm -rf -- "$APP_DIR"
mv "$STAGED_APP" "$APP_DIR"

echo "Created $APP_DIR"

# Shareable zip: the app plus a short install guide for people who don't build.
ZIP_PATH="$DIST_DIR/TokenCounter-share.zip"
SHARE_DIR="$(mktemp -d "$DIST_DIR/.share.XXXXXX")"
ditto "$APP_DIR" "$SHARE_DIR/TokenCounter.app"
cp "$PROJECT_DIR/Supporting/INSTALL.ko.txt" "$SHARE_DIR/설치 방법.txt"
rm -f -- "$ZIP_PATH"
(cd "$SHARE_DIR" && ditto -c -k --norsrc . "$ZIP_PATH")
rm -rf -- "$SHARE_DIR"
echo "Created $ZIP_PATH"
