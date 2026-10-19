#!/bin/bash # ==============================================================================
# Android Duo - Quick Launch Script for macOS
# ==============================================================================

# Ensure we are in the project root directory even if opened from Finder
cd "$(dirname "$0")" || exit 1

echo "============================================================"
echo "  🚀 Starting Android Duo (macOS Display & Touch Companion)  "
echo "============================================================"

# 1. Check Node.js
if ! command -v node >/dev/null 2>&1; then
    echo "❌ Node.js is not found!"
    echo "👉 Please install Node.js via Homebrew: brew install node"
    echo "   or download from https://nodejs.org/"
    read -rp "Press Enter to exit..."
    exit 1
fi

# 2. Check and build native Swift module if missing
if [ ! -f "native/mac_host" ] || [ "native/mac_host.swift" -nt "native/mac_host" ] || [ "native/virtual_display.m" -nt "native/mac_host" ] || [ "native/virtual_display.h" -nt "native/mac_host" ]; then
    echo "⚙️  Compiling native macOS capture engine (ScreenCaptureKit)..."
    if ! command -v swiftc >/dev/null 2>&1; then
        echo "❌ Xcode CLI tools not found. Run: xcode-select --install"
        read -rp "Press Enter to exit..."
        exit 1
    fi
    clang -fobjc-arc -c native/virtual_display.m -o native/virtual_display.o && swiftc -O -parse-as-library -import-objc-header native/virtual_display.h native/mac_host.swift native/virtual_display.o -o native/mac_host && codesign --force -s - --identifier com.daniel.androidduo -r='designated => identifier "com.daniel.androidduo"' native/mac_host
    if [ $? -ne 0 ]; then
        echo "❌ Compilation failed!"
        read -rp "Press Enter to exit..."
        exit 1
    fi
    echo "✅ Native engine compiled successfully."
fi

# 3. Check node_modules
if [ ! -d "node_modules" ]; then
    echo "📦 Installing npm dependencies..."
    npm install
fi

# 4. Optional: Check for connected ADB device via USB
if command -v adb >/dev/null 2>&1; then
    ADB_DEVICES=$(adb devices 2>/dev/null | grep -v "List" | grep "device$" | wc -l | tr -d ' ')
    if [ "$ADB_DEVICES" -gt 0 ]; then
        echo "⚡ Android device detected via USB! Setting up ADB reverse tunnel on port 3000..."
        adb reverse tcp:3000 tcp:3000
        # Prevent tablet screen from sleeping while plugged in to USB
        adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
        adb shell wm dismiss-keyguard >/dev/null 2>&1
        adb shell settings put global stay_on_while_plugged_in 3 >/dev/null 2>&1
        adb shell svc power stayon usb >/dev/null 2>&1
        adb shell settings put global policy_control immersive.full=* >/dev/null 2>&1
        echo "🚀 Directing tablet browser to USB tunnel (http://127.0.0.1:3000/?pwa=1)..."
        adb shell am start -n com.android.chrome/com.google.android.apps.chrome.Main -a android.intent.action.VIEW -d "http://127.0.0.1:3000/?pwa=1" >/dev/null 2>&1 || \
        adb shell am start -a android.intent.action.VIEW -d "http://127.0.0.1:3000/?pwa=1" >/dev/null 2>&1
        (sleep 1; adb shell input keyevent 141 >/dev/null 2>&1) &
        echo "✅ ADB reverse tunnel active: USB mode engaged."
    fi
fi

# 5. Start server
echo "🚀 Launching server..."
exec node server/index.js
