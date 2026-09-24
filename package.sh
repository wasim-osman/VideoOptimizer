#!/bin/bash
#
# Builds VideoOptimizer.app from the SwiftPM executable and wraps it in a DMG.
#
# The result is ad-hoc signed only. Without a Developer ID certificate it cannot be
# notarised, so macOS will quarantine it on any machine that did not build it — see
# the Installation section of README.md for what users have to do about that.
#
# usage: ./package.sh [version]

set -euo pipefail

VERSION="${1:-1.0.0}"
APP_NAME="VideoOptimizer"
BUILD_DIR=".build/release"
STAGE="$(mktemp -d)"
DIST="dist"
APP="$STAGE/$APP_NAME.app"

trap 'rm -rf "$STAGE"' EXIT

echo "==> Building release binary"
swift build -c release --product VideoOptimizerApp

echo "==> Running tests"
swift test >/dev/null

echo "==> Assembling $APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BUILD_DIR/VideoOptimizerApp" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>com.videooptimizer.app</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Video Files</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
                <string>public.mpeg-4</string>
                <string>public.avi</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Placeholder so the bundled-binary location is obvious to anyone building their own
# GPL ffmpeg (see README "Bundling ffmpeg").
cat > "$APP/Contents/Resources/bin/README" <<'NOTE'
Drop a statically linked `ffmpeg` and `ffprobe` here to make the app self-contained.
When this directory is empty the app falls back to /opt/homebrew/bin.
NOTE

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Building DMG"
mkdir -p "$DIST"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"

echo
echo "Done: $DMG ($(du -h "$DMG" | cut -f1))"
echo "Note: unsigned build — first launch needs right-click > Open, or:"
echo "  xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
