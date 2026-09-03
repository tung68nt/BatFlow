# 🔋 TulieBattery

> Giải pháp Giám sát & Quản lý Pin Chuyên Sâu dành cho macOS (Apple Silicon & Intel).  
> Phát triển bởi **Tulie Tech**.

---

## 🌟 Tính Năng Nổi Bật

- **Menu Bar Chuyên Nghiệp:**
  - Viên pin hiển thị trực quan dung tích, tự động đổi màu theo độ sáng nền (Light/Dark Mode).
  - Phân biệt rõ rệt 3 trạng thái nguồn:
    - ⚡ **Đang nạp sạc (`isCharging`):** Tia sét xanh ngọc lục bảo.
    - ⏸️ **Giữ mức sạc / Hold sạc (`power bypass`):** Hai vạch dọc `||` màu xanh dương Apple.
    - 🔋 **Dùng nguồn pin:** Đo dung lượng xả thực tế.
- **Popover Kính Mờ (Liquid Glass Popover):**
  - Hiển thị ước tính thời gian chính xác (đến mấy giờ sẽ đầy pin).
  - Tỷ lệ chu kỳ sạc thực tế (`/ 1.000 lần` chuẩn Apple).
  - Biểu đồ xả nạp và công suất điện tức thời (Watt, Volt, Ampe).
  - Thẻ điều khiển gom nhóm (Grouped Action Card) tinh tế: Báo cáo chi tiết (`⌘O`), Giới thiệu (`About`), Thoát (`⌘Q`).
- **Dashboard Phân Tích Chuyên Sâu:**
  - Cửa sổ chuẩn Native macOS (di chuyển, kéo thả bằng thanh tiêu đề mượt mà).
  - Thích ứng hoàn hảo theo Light Theme và Dark Theme của hệ thống.
  - Sơ đồ cổng kết nối Thunderbolt 4 / MagSafe 3 / HDMI / SDXC.
  - Xếp hạng tiến trình tiêu thụ năng lượng (Top Power Consumers).
  - So sánh 2 chuẩn đo pin: Chuẩn Apple Settings vs Chuẩn đo thô phần cứng.
- **Nhẹ & Tiết Kiệm Pin Tuyệt Đối:**
  - Viết bằng Swift thuần & AppKit/SwiftUI.
  - Chạy chế độ `LSUIElement = true` ngầm trên thanh Menu Bar, không làm chật Dock.

---

## 📁 Cấu Trúc Dự Án

```
/Users/tungnguyen/Code/TulieBattery/
├── src/
│   ├── BatteryBar.swift       # Mã nguồn chính Swift (Menu Bar, Popover, About Window, WebKit)
│   └── generate_report.py     # Engine trích xuất số liệu phần cứng & tạo Dashboard HTML
├── resources/
│   ├── Info.plist             # Metadata, phiên bản, quyền hệ thống
│   ├── applet.icns            # Icon ứng dụng Apple Continuous Squircle chuẩn Retina
│   └── battery_icon.png       # Favicon & icon vector 128x128
├── scripts/
│   ├── build.sh               # Kịch bản biên dịch 1-click ra /Applications/TulieBattery.app
│   └── make_dmg.sh            # Kịch bản đóng gói bộ cài đặt .dmg phân phối
├── releases/
│   └── TulieBattery-v1.0.0.dmg # File cài đặt DMG hoàn chỉnh
└── README.md
```

---

## 🛠️ Hướng Dẫn Phát Triển & Cập Nhật Phiên Bản

### 1. Biên dịch và chạy thử nghiệm
Chạy lệnh sau để build mã nguồn và tự động khởi chạy lại ứng dụng:
```bash
./scripts/build.sh
```

### 2. Đóng gói phiên bản mới (.dmg)
Để tạo file `.dmg` mới cho phiên bản cập nhật (ví dụ `1.0.1`):
```bash
./scripts/make_dmg.sh 1.0.1
```
File cài đặt sẽ được tạo tự động tại:
- `releases/TulieBattery-v1.0.1.dmg`
- Màn hình chính `~/Desktop/TulieBattery-v1.0.1.dmg`

### 3. Cập nhật số phiên bản trong Metadata
Chỉnh sửa file `resources/Info.plist`:
- `CFBundleShortVersionString`: Số phiên bản (ví dụ: `1.0.1`)
- `CFBundleVersion`: Mã bản dựng (ví dụ: `2026.09.05`)

---

## 📜 Bản Quyền
© 2026 **Tulie Tech**. All rights reserved.
