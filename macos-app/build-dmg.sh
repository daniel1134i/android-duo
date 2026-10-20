#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$ROOT_DIR/Android Duo.app"
DMG_PATH="$ROOT_DIR/Android Duo.dmg"
TEMP_DMG_DIR="$ROOT_DIR/.build_dmg_temp"

echo "💿 Creating Android Duo.dmg..."

# Ensure the app is built and standalone bundle is ready
bash "$SCRIPT_DIR/build.sh"

rm -rf "$TEMP_DMG_DIR"
mkdir -p "$TEMP_DMG_DIR"

# Copy Apps to staging dir
echo "📦 Preparing DMG staging directory..."
ditto "$APP_DIR" "$TEMP_DMG_DIR/Android Duo.app"
if [ -d "$ROOT_DIR/Android Duo HUD.app" ]; then
    ditto "$ROOT_DIR/Android Duo HUD.app" "$TEMP_DMG_DIR/Android Duo HUD.app"
fi

# Create symlink to /Applications for easy drag-and-drop installation
ln -s /Applications "$TEMP_DMG_DIR/Applications"

# Optional: Add volume icon
if [ -f "$ROOT_DIR/AppIcon.icns" ]; then
    cp "$ROOT_DIR/AppIcon.icns" "$TEMP_DMG_DIR/.VolumeIcon.icns"
fi

# Remove any old DMG
rm -f "$DMG_PATH"

echo "📀 Building compressed DMG image via hdiutil..."
hdiutil create \
    -volname "Android Duo" \
    -srcfolder "$TEMP_DMG_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# Cleanup staging directory
rm -rf "$TEMP_DMG_DIR"

# Verify DMG
if [ -f "$DMG_PATH" ]; then
    DMG_SIZE=$(ls -lh "$DMG_PATH" | awk '{print $5}')
    echo "✅ Successfully created DMG: $DMG_PATH ($DMG_SIZE)"
else
    echo "❌ Failed to create DMG"
    exit 1
fi
