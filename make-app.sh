#!/bin/bash
# Build TeachingHub and wrap the binary in a proper macOS .app bundle.
#
# Usage:
#   ./make-app.sh             # produces ./TeachingHub.app
#   ./make-app.sh /Applications  # also installs to /Applications
#
# Requires: Swift 5.9+ (xcode-select --install) and standard macOS bash/cp/plutil.

set -euo pipefail

APP_NAME="TeachingHub"
DISPLAY_NAME="Teaching Hub"
BUNDLE_ID="com.teachinghub.app"
VERSION="1.1.0"
BUILD_NUMBER="2"
MIN_OS="13.0"

# 1. Compile the Swift binary
echo "==> Building $APP_NAME (release)"
swift build -c release

BINARY_PATH=".build/release/$APP_NAME"
if [ ! -f "$BINARY_PATH" ]; then
    echo "Build failed — binary not at $BINARY_PATH"
    exit 1
fi

# 2. Lay out the .app bundle directory structure
APP_DIR="$APP_NAME.app"
echo "==> Creating $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# 3. Copy the binary and icon
cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
else
    echo "  (no Resources/AppIcon.icns found — bundle will use generic icon)"
fi

# 4. Write Info.plist
cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_OS</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Joe Rowing. MIT licensed.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Teaching Hub needs to see your calendars so you can pick which one to sync your lessons into, and write lesson events into the one you choose.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Teaching Hub needs to see your calendars so you can pick which one to sync your lessons into, and write lesson events into the one you choose. It only reads calendar metadata (names and sources) — not your other events.</string>
</dict>
</plist>
PLIST

# 5. Validate Info.plist
plutil -lint "$APP_DIR/Contents/Info.plist" > /dev/null

# 6. Force Finder to refresh the icon for this bundle
touch "$APP_DIR"

echo ""
echo "✓ Built $APP_DIR"
echo "  Run it: open $APP_DIR"
echo "  Or move it to /Applications and launch from Spotlight/Launchpad."

# 7. Optional install
if [ "${1:-}" = "/Applications" ] || [ "${1:-}" = "~/Applications" ]; then
    DEST="$1"
    DEST="${DEST/#\~/$HOME}"
    echo ""
    echo "==> Installing to $DEST/$APP_DIR"
    if [ -d "$DEST/$APP_DIR" ]; then
        rm -rf "$DEST/$APP_DIR"
    fi
    cp -R "$APP_DIR" "$DEST/"
    echo "✓ Installed. Open $DEST/$APP_DIR"
fi
