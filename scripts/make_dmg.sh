#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-1.0.0}"
APP_PATH="/Applications/BatFlow.app"
STAGING_DIR="/tmp/BatFlow_DMG_Staging"
OUTPUT_DMG="$DIR/releases/BatFlow-v$VERSION.dmg"
DESKTOP_DMG="/Users/tungnguyen/Desktop/BatFlow-v$VERSION.dmg"

echo "📦 Creating DMG Installer for BatFlow v$VERSION..."

# First run build to ensure the app is fresh
"$DIR/scripts/build.sh"

# Setup Staging directory
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy App Bundle
cp -R "$APP_PATH" "$STAGING_DIR/"

# Create symlink to /Applications for Drag-and-Drop install
ln -s /Applications "$STAGING_DIR/Applications"

# Clean old DMGs
rm -f "$OUTPUT_DMG" "$DESKTOP_DMG"
mkdir -p "$DIR/releases"

# Create Compressed Disk Image
hdiutil create -volname "BatFlow" \
               -srcfolder "$STAGING_DIR" \
               -ov \
               -format UDZO \
               "$OUTPUT_DMG"

# Also copy to Desktop for easy access
cp "$OUTPUT_DMG" "$DESKTOP_DMG"
rm -rf "$STAGING_DIR"

echo "🎉 Successfully created BatFlow DMG installer:"
echo "   👉 $OUTPUT_DMG"
echo "   👉 $DESKTOP_DMG"
