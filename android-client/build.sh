#!/usr/bin/env bash
set -euo pipefail

# Android Duo Android Client Build Script
# Uses OpenJDK 17 and Android SDK command-line build tools directly

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export PATH="$JAVA_HOME/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ANDROID_SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

if [ ! -d "$JAVA_HOME" ]; then
    echo "ERROR: JAVA_HOME not found at $JAVA_HOME" >&2
    exit 1
fi

if [ ! -d "$ANDROID_SDK" ]; then
    echo "ERROR: Android SDK not found at $ANDROID_SDK" >&2
    exit 1
fi

# Locate latest build-tools and android platform
BUILD_TOOLS_DIR=$(ls -d "$ANDROID_SDK/build-tools/"* 2>/dev/null | sort -V | tail -n 1)
PLATFORM_JAR=$(ls -d "$ANDROID_SDK/platforms/android-"*/android.jar 2>/dev/null | sort -V | tail -n 1)

if [ -z "$BUILD_TOOLS_DIR" ] || [ ! -d "$BUILD_TOOLS_DIR" ]; then
    echo "ERROR: No build-tools found in $ANDROID_SDK/build-tools" >&2
    exit 1
fi

if [ -z "$PLATFORM_JAR" ] || [ ! -f "$PLATFORM_JAR" ]; then
    echo "ERROR: No platform android.jar found in $ANDROID_SDK/platforms" >&2
    exit 1
fi

AAPT2="$BUILD_TOOLS_DIR/aapt2"
D8="$BUILD_TOOLS_DIR/d8"
ZIPALIGN="$BUILD_TOOLS_DIR/zipalign"
APKSIGNER="$BUILD_TOOLS_DIR/apksigner"
JAVAC="$JAVA_HOME/bin/javac"
JAR="$JAVA_HOME/bin/jar"
KEYTOOL="$JAVA_HOME/bin/keytool"

echo "=== Android Duo Client Build ==="
echo "Java Home:    $JAVA_HOME"
echo "Build Tools:  $BUILD_TOOLS_DIR"
echo "Platform Jar: $PLATFORM_JAR"

BUILD_DIR="$SCRIPT_DIR/build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/compiled" "$BUILD_DIR/gen" "$BUILD_DIR/obj" "$BUILD_DIR/apk"

# 1. Compile resources with aapt2
echo "-> [1/6] Compiling resources with aapt2..."
"$AAPT2" compile --dir res -o "$BUILD_DIR/compiled/res.zip"

# 2. Link resources and generate R.java
echo "-> [2/6] Linking resources with aapt2..."
"$AAPT2" link \
    -I "$PLATFORM_JAR" \
    --manifest AndroidManifest.xml \
    --java "$BUILD_DIR/gen" \
    -o "$BUILD_DIR/apk/unaligned.apk" \
    "$BUILD_DIR/compiled/res.zip" \
    --auto-add-overlay

# 3. Compile Java sources
echo "-> [3/6] Compiling Java sources with javac..."
find "$BUILD_DIR/gen" "$SCRIPT_DIR/src" -name "*.java" | sed 's/^/"/' | sed 's/$/"/' > "$BUILD_DIR/sources.txt"
"$JAVAC" -encoding UTF-8 \
    -cp "$PLATFORM_JAR" \
    -d "$BUILD_DIR/obj" \
    @"$BUILD_DIR/sources.txt"

# 4. Dex bytecode with d8
echo "-> [4/6] Converting bytecode with d8..."
"$JAR" -cf "$BUILD_DIR/classes.jar" -C "$BUILD_DIR/obj" .
"$D8" --lib "$PLATFORM_JAR" \
    --release \
    --min-api 21 \
    --output "$BUILD_DIR/apk" \
    "$BUILD_DIR/classes.jar"

# 5. Package classes.dex into unaligned APK
echo "-> [5/6] Packaging classes.dex..."
(cd "$BUILD_DIR/apk" && "$JAR" -uf unaligned.apk classes.dex)

# 6. Zipalign and sign APK
echo "-> [6/6] Aligning and signing APK..."
"$ZIPALIGN" -f 4 "$BUILD_DIR/apk/unaligned.apk" "$BUILD_DIR/apk/aligned.apk"

# Ensure debug keystore exists
KEYSTORE="$HOME/.android/debug.keystore"
if [ ! -f "$KEYSTORE" ]; then
    echo "Creating Android debug keystore at $KEYSTORE..."
    mkdir -p "$HOME/.android"
    "$KEYTOOL" -genkeypair -v \
        -keystore "$KEYSTORE" \
        -storepass android \
        -alias androiddebugkey \
        -keypass android \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -dname "CN=Android Debug,O=Android,C=US"
fi

OUTPUT_APK="$SCRIPT_DIR/android-duo.apk"
"$APKSIGNER" sign \
    --ks "$KEYSTORE" \
    --ks-pass pass:android \
    --key-pass pass:android \
    --out "$OUTPUT_APK" \
    "$BUILD_DIR/apk/aligned.apk"

# Verify signature
"$APKSIGNER" verify "$OUTPUT_APK"

echo "=== Build Complete ==="
echo "Output: $OUTPUT_APK"
ls -lh "$OUTPUT_APK"

# Optional install flag
if [[ "${1:-}" == "--install" || "${1:-}" == "-i" ]]; then
    echo "Installing to connected device via adb..."
    adb install -r "$OUTPUT_APK"
    adb shell am start -n com.androidduo.client/.MainActivity
fi
