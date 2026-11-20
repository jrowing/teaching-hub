#!/bin/bash
# Build a .dmg installer for TeachingHub.app.
#
# Usage:
#   ./make-dmg.sh           # plain .dmg with app + /Applications symlink
#   ./make-dmg.sh --pretty  # adds a background image and arranged icons
#
# Requires: macOS (uses hdiutil + osascript). Run after ./make-app.sh.

set -euo pipefail

APP_NAME="TeachingHub"
DISPLAY_NAME="Teaching Hub"
VERSION="1.1.0"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
VOLUME_NAME="$DISPLAY_NAME"
APP_DIR="${APP_NAME}.app"

PRETTY=false
if [ "${1:-}" = "--pretty" ]; then PRETTY=true; fi

# 1. Sanity check
if [ ! -d "$APP_DIR" ]; then
    echo "ERROR: $APP_DIR not found. Run ./make-app.sh first."
    exit 1
fi

# 2. Stage a clean folder with the .app and a symlink to /Applications
STAGING=".dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# 3. Build the .dmg
rm -f "$DMG_NAME"
TMP_DMG=".tmp-${DMG_NAME}"
rm -f "$TMP_DMG"

if [ "$PRETTY" = true ]; then
    echo "==> Building pretty $DMG_NAME"

    # Create a writable image we can mount and customize
    hdiutil create -volname "$VOLUME_NAME" \
        -srcfolder "$STAGING" \
        -ov -format UDRW "$TMP_DMG"

    # Mount it
    MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$TMP_DMG" | \
        grep '/Volumes/' | sed 's/.*\(\/Volumes\/.*\)/\1/' | head -1)
    if [ -z "$MOUNT_DIR" ]; then
        echo "ERROR: failed to mount $TMP_DMG"
        exit 1
    fi

    # Optionally drop a background image. If Resources/dmg-background.png exists,
    # use it; otherwise the .dmg just gets a plain background.
    if [ -f "Resources/dmg-background.png" ]; then
        mkdir -p "$MOUNT_DIR/.background"
        cp "Resources/dmg-background.png" "$MOUNT_DIR/.background/background.png"
        BACKGROUND_LINE='set background picture of viewOptions to file ".background:background.png"'
    else
        BACKGROUND_LINE='-- (no custom background)'
    fi

    # AppleScript to lay out the Finder window
    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 760, 480}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        $BACKGROUND_LINE
        set position of item "$APP_DIR" of container window to {140, 180}
        set position of item "Applications" of container window to {420, 180}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

    # Sync, unmount, convert to compressed read-only
    sync
    hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR"
    hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_NAME"
    rm -f "$TMP_DMG"

else
    echo "==> Building plain $DMG_NAME"
    hdiutil create -volname "$VOLUME_NAME" \
        -srcfolder "$STAGING" \
        -ov -format UDZO -imagekey zlib-level=9 \
        "$DMG_NAME"
fi

# 4. Cleanup
rm -rf "$STAGING"

# 5. Report
SIZE=$(du -h "$DMG_NAME" | cut -f1)
echo ""
echo "✓ Built $DMG_NAME ($SIZE)"
echo "  Test it: open $DMG_NAME"
echo "  Share it: just send the .dmg file."
