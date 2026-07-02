#!/usr/bin/env bash
#
# Assemble a macOS .app bundle from the SwiftPM-built executable.
# Usage: assemble-app.sh <debug|release> <display_name> <icon_basename> [log_path]
#
# No xcodebuild involved — this is the Ronin-style hand-assembly that works
# without Xcode's simulator components.
set -euo pipefail

CONFIG="$1"      # debug | release
DISPLAY="$2"     # e.g. "DevSpace Dev"
ICON="$3"        # icon basename in Resources, e.g. DevSpaceDev
LOG_PATH="${4:-}"

MACOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$MACOS_DIR/.build/$CONFIG/DevSpaceApp"
OUT="$MACOS_DIR/build"
APP="$OUT/$DISPLAY.app"
ICNS="$MACOS_DIR/Resources/$ICON.icns"
PB=/usr/libexec/PlistBuddy

[ -x "$BIN" ] || { echo "error: missing build product $BIN" >&2; exit 1; }
[ -f "$ICNS" ] || { echo "error: missing icon $ICNS" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/DevSpace"
cp "$MACOS_DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$ICNS" "$APP/Contents/Resources/$ICON.icns"

# Copy any SwiftPM resource bundles (e.g. Ghostty shaders/themes) so
# Bundle.module resolves them whether looked up beside the binary or in
# Resources.
shopt -s nullglob
for b in "$MACOS_DIR/.build/$CONFIG/"*.bundle; do
    cp -R "$b" "$APP/Contents/Resources/"
    cp -R "$b" "$APP/Contents/MacOS/"
done

"$PB" -c "Set :CFBundleDisplayName $DISPLAY" "$APP/Contents/Info.plist"
"$PB" -c "Set :CFBundleName $DISPLAY" "$APP/Contents/Info.plist"
"$PB" -c "Set :CFBundleIconFile $ICON" "$APP/Contents/Info.plist"

# CFBundleVersion (the build number shown as "Version X.Y.Z (N)" in the About
# panel) is the total commit count — monotonically increasing and valid Apple
# format, distinct from CFBundleShortVersionString (the marketing version the
# release pipeline bumps). Falls back to the Info.plist default when building
# outside a git checkout (e.g. from a source tarball).
BUILD_NUMBER="$(git -C "$MACOS_DIR" rev-list --count HEAD 2>/dev/null || true)"
if [ -n "$BUILD_NUMBER" ]; then
    "$PB" -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
if [ -n "$LOG_PATH" ]; then
    "$PB" -c "Add :DevSpaceLogPath string $LOG_PATH" "$APP/Contents/Info.plist" 2>/dev/null \
        || "$PB" -c "Set :DevSpaceLogPath $LOG_PATH" "$APP/Contents/Info.plist"
fi

# Ad-hoc sign (mirrors the existing Tauri ad-hoc signing; no Developer ID).
codesign --sign - --force --deep "$APP" >/dev/null 2>&1 \
    || codesign --sign - --force "$APP"

echo "✓ assembled $APP"
