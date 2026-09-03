# ⚡ BatFlow

> Giải pháp Giám sát Dòng Chảy Năng Lượng & Quản lý Pin Chuyên Sâu cho macOS.  
> Phát triển bởi **Tulie Tech**.

---

## 🌟 Tính Năng Độc Quyền của BatFlow

- **Menu Bar Thông Minh:**
  - Hiển thị dung tích pin thời gian thực, tương thích độ sáng nền (Light/Dark Mode).
  - Phân biệt rõ rệt 3 trạng thái năng lượng:
    - ⚡ **Nạp điện (`isCharging`):** Tia sét xanh ngọc lục bảo.
    - ⏸️ **Giữ sạc / Dòng chảy ngoài (`power bypass`):** Hai vạch dọc `||` xanh dương Apple.
    - 🔋 **Xả pin:** Đo dung lượng xả thực tế.
- **Liquid Glass Popover:**
  - Thời gian dự kiến đầy / cạn chính xác đến từng phút và giờ cụ thể.
  - Tỷ lệ chu kỳ sạc thực tế (`/ 1.000 lần` chuẩn Apple).
  - Thẻ điều khiển gom nhóm (Grouped Action Card) tinh tế:
    - Báo cáo phân tích chi tiết (`⌘O`)
    - Giới thiệu BatFlow (`v1.0.0`)
    - Thoát BatFlow (`⌘Q`)
- **Dashboard Phân Tích Dòng Chảy Điện Năng (Power Flow):**
  - Cửa sổ Native macOS có thể di chuyển kéo thả tự do.
  - Đo lường công suất củ sạc (Watt), dòng nạp vào pin (+W), công suất phần cứng tiêu thụ (W).
  - Sơ đồ cổng Thunderbolt 4, MagSafe 3, HDMI, SDXC.
  - Xếp hạng tiến trình ngốn pin (Top Power Consumers).
  - So sánh đối chiếu 2 chuẩn đo pin: Apple Settings vs Đo thô phần cứng.
- **Kiến Trúc & Bảo Mật Chuẩn Quốc Tế:**
  - 100% Hermetic App Bundle, không hardcode đường dẫn người dùng.
  - Chống XSS qua cơ chế sanitize dữ liệu tiến trình.
  - Lưu trữ dữ liệu an toàn tại `~/Library/Application Support/BatFlow/`.

---

## 📁 Cấu Trúc Dự Án

```
/Users/tungnguyen/Code/BatFlow/
├── src/
│   ├── BatFlow.swift          # Mã nguồn chính Swift (Menu Bar, Popover, About Window, WebKit)
│   └── generate_report.py     # Engine phân tích dữ liệu phần cứng & tạo Dashboard HTML
├── resources/
│   ├── Info.plist             # Metadata com.tulietech.batflow
│   ├── applet.icns            # Icon ứng dụng Apple Continuous Squircle Retina
│   └── battery_icon.png       # Vector icon 128x128
├── scripts/
│   ├── build.sh               # Kịch bản biên dịch 1-click ra /Applications/BatFlow.app
│   └── make_dmg.sh            # Kịch bản đóng gói bộ cài đặt BatFlow.dmg
├── releases/
│   └── BatFlow-v1.0.0.dmg     # File cài đặt DMG nén chính thức
└── README.md
```

---

## 🛠️ Hướng Dẫn Biên Dịch & Đóng Gói

### 1. Biên dịch và khởi chạy:
```bash
./scripts/build.sh
```

### 2. Đóng gói bộ cài đặt DMG:
```bash
./scripts/make_dmg.sh 1.0.0
```
File `.dmg` sẽ được xuất tự động tại:
- `releases/BatFlow-v1.0.0.dmg`
- `~/Desktop/BatFlow-v1.0.0.dmg`

---

## 📜 Bản Quyền
© 2026 **Tulie Tech**. All rights reserved.
