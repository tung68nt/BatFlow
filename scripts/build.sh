#!/bin/bash
set -e

# Usage: ./scripts/build.sh [output.app]
#   Without arguments: installs to /Applications/BatFlow.app and relaunches it.
#   With a path: only builds the bundle there (used by make_dmg.sh and for testing).

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-/Applications/BatFlow.app}"
MIN_OS="11.0"

echo "🔨 Building BatFlow (macOS $MIN_OS+)..."

# Ensure target app bundle structure
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy Metadata & Assets into App Bundle
cp "$DIR/resources/Info.plist" "$APP_PATH/Contents/"
cp "$DIR/resources/applet.icns" "$APP_PATH/Contents/Resources/"
cp "$DIR/resources/battery_icon.png" "$APP_PATH/Contents/Resources/"

# Remove artifacts shipped by versions before 1.1 (Python report engine)
rm -f "$APP_PATH/Contents/Resources/generate_report.py" "$APP_PATH/Contents/Resources/battery_report.html"

# Find all Swift modular files (ensuring main.swift is included)
SWIFT_FILES=$(find "$DIR/src" -name "*.swift" -type f | sort)

# Compile one optimized slice per architecture
BUILD_TMP="$(mktemp -d)"
trap 'rm -rf "$BUILD_TMP"' EXIT

compile_slice() {
    swiftc -O \
        -target "$1-apple-macos$MIN_OS" \
        -framework SwiftUI \
        -framework AppKit \
        -framework IOKit \
        -framework UserNotifications \
        $SWIFT_FILES \
        -o "$BUILD_TMP/BatFlow-$1"
}

compile_slice arm64

# The Intel slice needs a toolchain that still ships x86_64 Swift runtime libraries (recent ones may not)
if compile_slice x86_64 2>"$BUILD_TMP/x86_64.log"; then
    lipo -create "$BUILD_TMP/BatFlow-arm64" "$BUILD_TMP/BatFlow-x86_64" -output "$APP_PATH/Contents/MacOS/BatFlow"
    echo "   Kiến trúc: arm64 + x86_64"
else
    cp "$BUILD_TMP/BatFlow-arm64" "$APP_PATH/Contents/MacOS/BatFlow"
    echo "⚠️  Toolchain hiện tại không build được lát x86_64, bản này chỉ chạy trên Apple Silicon."
fi
codesign --force --sign - "$APP_PATH" >/dev/null 2>&1 || true

touch "$APP_PATH"
echo "✅ Build completed successfully: $APP_PATH"

if [ -n "$1" ]; then
    exit 0
fi

# Terminate old TulieBattery if running
killall TulieBattery 2>/dev/null || true

# Relaunch BatFlow
echo "🔄 Launching BatFlow..."
killall BatFlow 2>/dev/null || true
sleep 0.5
open "$APP_PATH"
echo "🚀 BatFlow launched successfully!"
