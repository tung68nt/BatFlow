#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DIR/resources/Info.plist")}"
STAGING_DIR="$(mktemp -d)/BatFlow_DMG_Staging"
OUTPUT_DMG="$DIR/releases/BatFlow-v$VERSION.dmg"
DESKTOP_DMG="$HOME/Desktop/BatFlow-v$VERSION.dmg"

echo "📦 Creating DMG Installer for BatFlow v$VERSION..."

# 1. Build a fresh app straight into the staging folder (one bundle covers macOS 11 and later)
mkdir -p "$STAGING_DIR"
"$DIR/scripts/build.sh" "$STAGING_DIR/BatFlow.app"

# 2. Add helpful guide text
cat << 'GUIDE' > "$STAGING_DIR/HUONG_DAN_CAI_DAT.txt"
⚡ BatFlow - Hướng Dẫn Cài Đặt (Tulie Tech)
============================================================
BatFlow.app chạy trên macOS 11 (Big Sur) trở lên.
Giao diện Liquid Glass hiển thị đầy đủ từ macOS 26; các bản
cũ hơn dùng nền kính mờ tương đương.

Cách cài đặt:
• Kéo thả BatFlow.app vào biểu tượng thư mục "Applications" bên cạnh.
• Mở BatFlow từ Launchpad hoặc Spotlight (phím tắt ⌘ + Space).
============================================================
© 2026 Tulie Tech. All rights reserved.
GUIDE

# 3. Create symlink to /Applications for Drag-and-Drop install
ln -s /Applications "$STAGING_DIR/Applications"

# 4. Clean old DMGs
rm -f "$OUTPUT_DMG" "$DESKTOP_DMG"
mkdir -p "$DIR/releases"

# 5. Create Compressed Disk Image
echo "💿 Compressing DMG file..."
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
echo "🔐 SHA-256 (điền vào trường \"sha256\" của version.json): $(shasum -a 256 "$OUTPUT_DMG" | cut -d' ' -f1)"
