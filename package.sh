#!/bin/bash
#
# Builds VideoOptimizer.app from the SwiftPM executable and wraps it in a DMG.
#
# By default this bundles a self-contained ffmpeg/ffprobe (see scripts/bundle-runtime.py)
# so the DMG works standalone with no Homebrew dependency. Pass --no-ffmpeg to skip that
# and ship the app without it (it will then fall back to /opt/homebrew/bin at runtime,
# same as a debug build).
#
# The result is ad-hoc signed only. Without a Developer ID certificate it cannot be
# notarised, so macOS will quarantine it on any machine that did not build it — see
# the Installation section of README.md for what users have to do about that.
#
# usage: ./package.sh [version] [--no-ffmpeg]

set -euo pipefail

VERSION="1.0.0"
BUNDLE_FFMPEG=1
for arg in "$@"; do
    case "$arg" in
        --no-ffmpeg) BUNDLE_FFMPEG=0 ;;
        *) VERSION="$arg" ;;
    esac
done

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

if [ "$BUNDLE_FFMPEG" = "1" ]; then
    SYSTEM_FFMPEG="$(command -v ffmpeg || true)"
    SYSTEM_FFPROBE="$(command -v ffprobe || true)"
    if [ -z "$SYSTEM_FFMPEG" ] || [ -z "$SYSTEM_FFPROBE" ]; then
        echo "==> No system ffmpeg/ffprobe found — building without a bundled runtime"
        echo "    (install with 'brew install ffmpeg' to produce a self-contained DMG)"
        BUNDLE_FFMPEG=0
    else
        echo "==> Bundling ffmpeg ($SYSTEM_FFMPEG) and its libraries"
        cp "$SYSTEM_FFMPEG" "$APP/Contents/Resources/bin/ffmpeg"
        cp "$SYSTEM_FFPROBE" "$APP/Contents/Resources/bin/ffprobe"
        chmod +x "$APP/Contents/Resources/bin/ffmpeg" "$APP/Contents/Resources/bin/ffprobe"
        python3 scripts/bundle-runtime.py "$APP"
        cp THIRD_PARTY_LICENSES.md "$APP/Contents/Resources/"
    fi
fi

if [ "$BUNDLE_FFMPEG" = "0" ]; then
    mkdir -p "$APP/Contents/Resources/bin"
    cat > "$APP/Contents/Resources/bin/README" <<'NOTE'
This build does not bundle ffmpeg — the app falls back to /opt/homebrew/bin/ffmpeg.
Run package.sh without --no-ffmpeg (and with ffmpeg on PATH) to bundle it.
NOTE
fi

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
