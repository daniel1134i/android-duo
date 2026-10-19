#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$ROOT_DIR/Android Duo.app"

echo "🔨 Building Android Duo.app..."

# 1. Compile Swift application
swiftc -O -parse-as-library \
    -target arm64-apple-macos12.3 \
    "$SCRIPT_DIR/main.swift" \
    -o "$SCRIPT_DIR/Android Duo"

# 2. Setup bundle structure
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# 3. Move binary
mv "$SCRIPT_DIR/Android Duo" "$APP_DIR/Contents/MacOS/Android Duo"
chmod +x "$APP_DIR/Contents/MacOS/Android Duo"

# 4. Copy Icon
if [ -f "$ROOT_DIR/AppIcon.icns" ]; then
    cp "$ROOT_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# 5. Create Info.plist
cat << 'EOF' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Android Duo</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.daniel.androidduo</string>
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

# 6. Ad-hoc codesign bundle with stable designated requirement so macOS TCC remembers screen recording permissions
echo "🔏 Signing application binary and bundle with stable designated requirement..."
BUNDLE_ID="com.daniel.androidduo"
codesign --force -s - --identifier "$BUNDLE_ID" -r="designated => identifier \"$BUNDLE_ID\"" "$APP_DIR/Contents/MacOS/Android Duo"
codesign --force -s - --identifier "$BUNDLE_ID" -r="designated => identifier \"$BUNDLE_ID\"" "$APP_DIR"

# 7. Ensure application is discoverable in /Applications for macOS System Settings picker
echo "🔗 Linking to /Applications for System Settings accessibility..."
ln -sfn "$APP_DIR" "/Applications/Android Duo.app" 2>/dev/null || true

echo "✅ Successfully built and signed: $APP_DIR"

