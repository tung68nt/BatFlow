#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-1.0.0}"
APP_PATH="/Applications/BatFlow.app"
STAGING_DIR="/tmp/BatFlow_DMG_Staging"
OUTPUT_DMG="$DIR/releases/BatFlow-v$VERSION.dmg"
DESKTOP_DMG="/Users/tungnguyen/Desktop/BatFlow-v$VERSION.dmg"

echo "📦 Creating Multi-macOS DMG Installer for BatFlow v$VERSION..."

# 1. First run build to ensure the primary app is fresh
"$DIR/scripts/build.sh"

# 2. Setup Staging directory
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# 3. Copy Primary App Bundle (macOS 12.0+ Monterey, Ventura, Sonoma, Sequoia)
echo "📂 Packaging primary BatFlow.app (macOS 12.0+)..."
cp -R "$APP_PATH" "$STAGING_DIR/BatFlow.app"

# 4. Build Legacy Compatibility App Bundle (macOS 11.0 Big Sur)
LEGACY_APP_NAME="BatFlow (macOS 11 Big Sur).app"
LEGACY_APP_PATH="$STAGING_DIR/$LEGACY_APP_NAME"
echo "🔨 Building compatibility version: $LEGACY_APP_NAME..."
mkdir -p "$LEGACY_APP_PATH/Contents/MacOS"
mkdir -p "$LEGACY_APP_PATH/Contents/Resources"

cp "$DIR/resources/Info-Legacy.plist" "$LEGACY_APP_PATH/Contents/Info.plist"
cp "$DIR/resources/applet.icns" "$LEGACY_APP_PATH/Contents/Resources/"
cp "$DIR/resources/battery_icon.png" "$LEGACY_APP_PATH/Contents/Resources/"
cp "$DIR/src/generate_report.py" "$LEGACY_APP_PATH/Contents/Resources/"
python3 "$DIR/src/generate_report.py" "$LEGACY_APP_PATH/Contents/Resources/battery_report.html" 100 || true
chmod 644 "$LEGACY_APP_PATH/Contents/Resources/battery_report.html" 2>/dev/null || true
chmod 644 "$LEGACY_APP_PATH/Contents/Resources/generate_report.py" 2>/dev/null || true

SWIFT_FILES=$(find "$DIR/src" -name "*.swift" -type f | sort)

swiftc -O \
    -target arm64-apple-macos11.0 \
    -framework SwiftUI \
    -framework AppKit \
    -framework WebKit \
    -framework IOKit \
    -framework UserNotifications \
    $SWIFT_FILES \
    -o "$LEGACY_APP_PATH/Contents/MacOS/BatFlow"

touch "$LEGACY_APP_PATH"

# 5. Add helpful guide text
cat << 'EOF' > "$STAGING_DIR/HUONG_DAN_CAI_DAT.txt"
⚡ BatFlow - Hướng Dẫn Cài Đặt (Tulie Tech)
============================================================
Bộ cài đặt DMG đã được đóng gói sẵn 2 phiên bản tương thích:

1. BatFlow.app
   👉 Khuyên dùng cho macOS 12 (Monterey), 13 (Ventura), 14 (Sonoma), 15+ (Sequoia).
   👉 Bản chuẩn tối ưu hóa tối đa hiệu năng.

2. BatFlow (macOS 11 Big Sur).app
   👉 Dành riêng cho máy Mac chạy hệ điều hành macOS 11 (Big Sur).
   👉 Đầy đủ tính năng giám sát dòng chảy năng lượng thời gian thực.

Cách cài đặt:
• Kéo thả phiên bản phù hợp vào biểu tượng thư mục "Applications" bên cạnh.
• Mở BatFlow từ Launchpad hoặc Spotlight (phím tắt ⌘ + Space).
============================================================
© 2026 Tulie Tech. All rights reserved.
EOF

# 6. Create symlink to /Applications for Drag-and-Drop install
ln -s /Applications "$STAGING_DIR/Applications"

# 7. Clean old DMGs
rm -f "$OUTPUT_DMG" "$DESKTOP_DMG"
mkdir -p "$DIR/releases"

# 8. Create Compressed Disk Image
echo "💿 Compressing DMG file..."
hdiutil create -volname "BatFlow" \
               -srcfolder "$STAGING_DIR" \
               -ov \
               -format UDZO \
               "$OUTPUT_DMG"

# Also copy to Desktop for easy access
cp "$OUTPUT_DMG" "$DESKTOP_DMG"
rm -rf "$STAGING_DIR"

echo "🎉 Successfully created Multi-macOS BatFlow DMG installer:"
echo "   👉 $OUTPUT_DMG"
echo "   👉 $DESKTOP_DMG"
