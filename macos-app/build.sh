#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$ROOT_DIR/Android Duo.app"

echo "🔨 Building Android Duo.app..."

# 0. Ensure native binary is built and present
if [ ! -f "$ROOT_DIR/native/mac_host" ]; then
    echo "⚙️ Building native host..."
    (cd "$ROOT_DIR" && npm run build:native)
fi

# 1. Compile Swift application
swiftc -O -parse-as-library \
    -target arm64-apple-macos12.3 \
    "$SCRIPT_DIR/main.swift" \
    -o "$SCRIPT_DIR/Android Duo"

# 2. Setup bundle structure
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources/app"

# 3. Move binary
mv "$SCRIPT_DIR/Android Duo" "$APP_DIR/Contents/MacOS/Android Duo"
chmod +x "$APP_DIR/Contents/MacOS/Android Duo"

# 4. Copy Icon
if [ -f "$ROOT_DIR/AppIcon.icns" ]; then
    cp "$ROOT_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# 5. Bundle standalone backend (server, public, native mac_host, node_modules)
echo "📦 Bundling standalone application assets..."
mkdir -p "$APP_DIR/Contents/Resources/app/server"
mkdir -p "$APP_DIR/Contents/Resources/app/public"
mkdir -p "$APP_DIR/Contents/Resources/app/native"

cp "$ROOT_DIR/server/index.js" "$APP_DIR/Contents/Resources/app/server/"
cp -R "$ROOT_DIR/public/"* "$APP_DIR/Contents/Resources/app/public/"
cp "$ROOT_DIR/native/mac_host" "$APP_DIR/Contents/Resources/app/native/"
chmod +x "$APP_DIR/Contents/Resources/app/native/mac_host"
if [ -d "$ROOT_DIR/node_modules" ]; then
    cp -R "$ROOT_DIR/node_modules" "$APP_DIR/Contents/Resources/app/"
fi
cp "$ROOT_DIR/package.json" "$APP_DIR/Contents/Resources/app/"

# 6. Create Info.plist
cat << EOF > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Android Duo</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.androidduo.app</string>
    <key>CFBundleName</key>
    <string>Android Duo</string>
    <key>CFBundleDisplayName</key>
    <string>Android Duo</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.3</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Android Duo требует доступ к записи экрана для беспроводной трансляции дисплея на планшет Xiaomi Pad SE.</string>
</dict>
</plist>
EOF

# 7. Ad-hoc codesign inner and outer bundles with stable designated requirement
echo "🔏 Signing application binary and bundle..."
BUNDLE_ID="com.androidduo.app"
codesign --force -s - --identifier "$BUNDLE_ID" -r="designated => identifier \"$BUNDLE_ID\"" "$APP_DIR/Contents/Resources/app/native/mac_host"
codesign --force -s - --identifier "$BUNDLE_ID" -r="designated => identifier \"$BUNDLE_ID\"" "$APP_DIR/Contents/MacOS/Android Duo"
codesign --force -s - --identifier "$BUNDLE_ID" -r="designated => identifier \"$BUNDLE_ID\"" "$APP_DIR"

# 8. Install application into /Applications for macOS Launchpad and System Settings
echo "📦 Installing Android Duo.app into /Applications..."
rm -rf "/Applications/Android Duo.app"
ditto "$APP_DIR" "/Applications/Android Duo.app"
codesign --force -s - --identifier "$BUNDLE_ID" -r="designated => identifier \"$BUNDLE_ID\"" "/Applications/Android Duo.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Android Duo.app"

defaults write com.apple.dock ResetLaunchPad -bool true
killall Dock 2>/dev/null || true

# Clean up standalone HUD from /Applications if present
rm -rf "/Applications/Android Duo HUD.app"
rm -rf "$ROOT_DIR/Android Duo HUD.app"

echo "✅ Successfully built and signed: $APP_DIR"

