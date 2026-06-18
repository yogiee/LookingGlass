#!/bin/bash
# Build Looking Glass as a macOS .app bundle (SwiftPM executable + embedded Python sidecar).
# Usage: ./scripts/build-app.sh [release|debug]
#
# Produces build/LookingGlass.app and (release) build/LookingGlass.dmg.
# The Python sidecar + a self-contained venv are embedded at
# Contents/Resources/sidecar so the app runs with no external setup beyond
# Homebrew Python (for the stdlib) being present.

set -euo pipefail

CONFIG="${1:-release}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"

APP_NAME="LookingGlass"          # bundle + binary name (no spaces)
DISPLAY_NAME="Looking Glass"     # shown in Finder / Dock / menu bar
BUNDLE_ID="com.yogi.LookingGlass"
VERSION="0.8.2"
BUILD_NUMBER="13"

# Shared EdDSA public key for Sparkle (private key in Keychain, machine-bound).
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-k47OPDePNJN2Iyiu28Hz73RzNv/GHyryeSPWvGhv1+c=}"
SUFEED_URL="https://raw.githubusercontent.com/yogiee/LookingGlass/main/appcast.xml"

# Homebrew Python used to create the embedded venv (interpreter is copied via --copies).
HOST_PYTHON="${HOST_PYTHON:-/opt/homebrew/bin/python3}"

echo "=== Building $DISPLAY_NAME ($CONFIG) v$VERSION ==="

# ── 1. Compile ───────────────────────────────────────────────────────────────
echo "  [1/8] Compiling with SwiftPM..."
if [ "$CONFIG" = "release" ]; then
    swift build -c release --package-path "$PROJECT_DIR"
    BUILD_OUT="$PROJECT_DIR/.build/release"
else
    swift build --package-path "$PROJECT_DIR"
    BUILD_OUT="$PROJECT_DIR/.build/debug"
fi
BUILT_BINARY="$BUILD_OUT/$APP_NAME"
[ -f "$BUILT_BINARY" ] || { echo "ERROR: binary not found at $BUILT_BINARY"; exit 1; }

# ── 2. Bundle skeleton ───────────────────────────────────────────────────────
echo "  [2/8] Creating app bundle..."
APP="$BUILD_DIR/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# ── 3. Executable + Sparkle framework ────────────────────────────────────────
echo "  [3/8] Copying executable + Sparkle.framework..."
cp "$BUILT_BINARY" "$APP/Contents/MacOS/$APP_NAME"

SPARKLE_FW="$BUILD_OUT/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
else
    echo "  WARNING: Sparkle.framework not found at $SPARKLE_FW"
fi

# SwiftPM resource bundle (avatars/backgrounds load from here via Bundle.module).
RES_BUNDLE="$BUILD_OUT/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$RES_BUNDLE" ]; then
    cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
else
    echo "  WARNING: resource bundle not found at $RES_BUNDLE"
fi

# ── 4. Embed Python sidecar + self-contained venv ────────────────────────────
echo "  [4/8] Embedding sidecar + venv (this pip-installs deps)..."
SIDECAR_DST="$APP/Contents/Resources/sidecar"
rsync -a --exclude='.venv' --exclude='__pycache__' --exclude='*.pyc' \
    "$PROJECT_DIR/sidecar/" "$SIDECAR_DST/"

[ -x "$HOST_PYTHON" ] || { echo "ERROR: Homebrew Python not at $HOST_PYTHON (set HOST_PYTHON)"; exit 1; }
# --copies puts a real python binary in the venv (not a symlink) so it travels.
"$HOST_PYTHON" -m venv --copies "$SIDECAR_DST/.venv"
"$SIDECAR_DST/.venv/bin/pip" install -q --upgrade pip
"$SIDECAR_DST/.venv/bin/pip" install -q -r "$SIDECAR_DST/requirements.txt"

# `venv --copies` bakes the version-PINNED Cellar dylib path into each copied
# interpreter (e.g. .../Cellar/python@3.14/3.14.5/.../Python). A Homebrew patch
# bump (3.14.5 → 3.14.6) deletes that exact dir, so the embedded python can no
# longer load its own runtime → the sidecar never starts → the app shows
# "Ollama offline". Repoint to the stable unversioned `opt` symlink, which always
# tracks the current build and is ABI-stable across patch releases. The deep
# codesign in step 8 re-signs these, so no manual re-sign is needed.
VENV_BIN="$SIDECAR_DST/.venv/bin"
OLD_DYLIB="$(otool -L "$VENV_BIN/python3" 2>/dev/null | awk '/Cellar\/python@/{print $1; exit}')"
if [ -n "$OLD_DYLIB" ]; then
    # /opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/... → /opt/homebrew/opt/python@3.14/Frameworks/...
    NEW_DYLIB="$(printf '%s' "$OLD_DYLIB" | sed -E 's#/Cellar/(python@[0-9.]+)/[^/]+/#/opt/\1/#')"
    if [ -f "$NEW_DYLIB" ]; then
        for b in python python3 python3.* ; do
            [ -f "$VENV_BIN/$b" ] && install_name_tool -change "$OLD_DYLIB" "$NEW_DYLIB" "$VENV_BIN/$b" 2>/dev/null || true
        done
        echo "        repointed venv interpreter → $NEW_DYLIB (survives brew patch upgrades)"
    fi
fi

# ── 5. Info.plist ────────────────────────────────────────────────────────────
echo "  [5/8] Writing Info.plist..."
cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
	<key>CFBundleName</key><string>$DISPLAY_NAME</string>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Yogi. All rights reserved.</string>
	<key>LSUIElement</key><false/>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key><true/>
	</dict>
	<key>SUFeedURL</key><string>$SUFEED_URL</string>
	<key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
</dict>
</plist>
PLIST

# ── 6. App icon (.icns) ──────────────────────────────────────────────────────
echo "  [6/8] Generating AppIcon.icns..."
APPICONSET="$PROJECT_DIR/LookingGlass/Assets.xcassets/AppIcon.appiconset"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
# The appiconset already uses iconutil's naming convention.
for f in icon_16x16 icon_16x16@2x icon_32x32 icon_32x32@2x \
         icon_128x128 icon_128x128@2x icon_256x256 icon_256x256@2x \
         icon_512x512 icon_512x512@2x; do
    [ -f "$APPICONSET/$f.png" ] && cp "$APPICONSET/$f.png" "$ICONSET/$f.png"
done
if iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$ICONSET" 2>/dev/null; then
    :
else
    echo "  WARNING: iconutil failed — falling back to runtime icon only"
fi
rm -rf "$ICONSET"

# ── 7. Ad-hoc code sign (Apple Silicon requires a signature to run) ──────────
echo "  [7/8] Ad-hoc code signing..."
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign reported warnings — ok for personal/unsigned)"

# ── 8. DMG (release only) ────────────────────────────────────────────────────
if [ "$CONFIG" != "release" ]; then
    echo ""
    echo "=== Debug build complete ==="
    echo "  App: $APP"
    echo "  Run: open \"$APP\""
    exit 0
fi

echo "  [8/8] Creating installer DMG..."
DMG="$BUILD_DIR/$APP_NAME.dmg"
TMP_DMG="$BUILD_DIR/tmp_$APP_NAME.dmg"
STAGING="$BUILD_DIR/dmg_staging"
VOL_NAME="$DISPLAY_NAME $VERSION"

rm -f "$DMG" "$TMP_DMG"; rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

APP_SIZE_MB=$(du -sm "$STAGING" | cut -f1)
DMG_SIZE_MB=$((APP_SIZE_MB + 40))
hdiutil create -srcfolder "$STAGING" -volname "$VOL_NAME" -fs HFS+ \
    -format UDRW -size "${DMG_SIZE_MB}m" "$TMP_DMG" > /dev/null

MOUNT_DIR="/Volumes/$VOL_NAME"
hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen -mountpoint "$MOUNT_DIR" > /dev/null
osascript << APPLESCRIPT || true
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 150, 760, 470}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 120
        set position of item "$APP_NAME.app" of container window to {140, 160}
        set position of item "Applications" of container window to {420, 160}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT
sync
hdiutil detach "$MOUNT_DIR" > /dev/null
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" > /dev/null
rm -f "$TMP_DMG"; rm -rf "$STAGING"

# Sign the DMG with EdDSA for Sparkle.
SIGN_UPDATE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
echo ""
if [ -f "$SIGN_UPDATE" ]; then
    echo "  Signing DMG for Sparkle..."
    SIG_LINE="$("$SIGN_UPDATE" "$DMG" 2>/dev/null || true)"
    echo "  $SIG_LINE"
    DMG_SIZE=$(stat -f%z "$DMG")
    echo ""
    echo "  *** appcast.xml enclosure attributes:"
    echo "      url=\"https://github.com/yogiee/LookingGlass/releases/download/v$VERSION/$APP_NAME.dmg\""
    echo "      sparkle:version=\"$BUILD_NUMBER\""
    echo "      sparkle:shortVersionString=\"$VERSION\""
    echo "      $SIG_LINE"
    echo "      (length is included in the line above; DMG size = $DMG_SIZE bytes)"
else
    echo "  Note: sign_update not found at $SIGN_UPDATE — run 'swift package resolve' first."
fi

echo ""
echo "=== Build complete ==="
echo "  App: $APP ($(du -sh "$APP" | cut -f1))"
echo "  DMG: $DMG ($(du -sh "$DMG" | cut -f1))"
echo "  Install: open \"$DMG\""
