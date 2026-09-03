#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="/Applications/TulieBattery.app"

echo "🔨 Building TulieBattery (Hermetic & Production Ready)..."

# Ensure target app bundle structure
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy Metadata & Assets into App Bundle
cp "$DIR/resources/Info.plist" "$APP_PATH/Contents/"
cp "$DIR/resources/applet.icns" "$APP_PATH/Contents/Resources/"
cp "$DIR/resources/battery_icon.png" "$APP_PATH/Contents/Resources/"
cp "$DIR/src/generate_report.py" "$APP_PATH/Contents/Resources/"

# Compile Swift Binary with optimization
swiftc -O \
    -framework SwiftUI \
    -framework AppKit \
    -framework WebKit \
    "$DIR/src/BatteryBar.swift" \
    -o "$APP_PATH/Contents/MacOS/TulieBattery"

touch "$APP_PATH"
echo "✅ Build completed successfully: $APP_PATH"

# Relaunch if currently running
if pgrep -x "TulieBattery" > /dev/null; then
    echo "🔄 Relaunching TulieBattery..."
    killall TulieBattery 2>/dev/null || true
    sleep 0.5
    open "$APP_PATH"
    echo "🚀 TulieBattery relaunched!"
fi
