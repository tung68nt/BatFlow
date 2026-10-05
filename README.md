# ⚡ BatFlow

> Giải pháp Giám sát Dòng Chảy Năng Lượng & Quản lý Pin Chuyên Sâu cho macOS.  
> Phát triển bởi **Tulie Tech**.

---

## 🌟 Tính Năng của BatFlow

- **Menu Bar Thông Minh:**
  - Hiển thị dung tích pin thời gian thực, tương thích độ sáng nền (Light/Dark Mode).
  - Phân biệt 3 trạng thái năng lượng: ⚡ đang nạp, ⏸️ giữ sạc / dùng nguồn ngoài, 🔋 xả pin.
- **Popover Liquid Glass:**
  - Dùng vật liệu Liquid Glass của hệ thống trên macOS 26+, tự chuyển sang kính mờ (vibrancy) trên macOS 11–15.
  - Thời gian dự kiến đầy / cạn, nguồn cấp, chu kỳ, nhiệt độ, sức khỏe pin, giới hạn sạc macOS đang áp dụng.
  - Top 3 ứng dụng tiêu thụ năng lượng theo chỉ số Energy Impact thật của macOS.
- **Dashboard native (SwiftUI):**
  - Tab **Tổng quan**: dòng nạp/xả, công suất củ sạc, hợp đồng USB-PD, tải hệ thống, sức khỏe pin, nhật ký nguồn, thời gian màn hình sáng.
  - Sơ đồ cổng đọc trực tiếp từ bộ điều khiển cổng trong IORegistry nên đúng với từng máy
    (MacBook Air 2 cổng, Air có MagSafe, MacBook Pro 13/14/16 inch) và chỉ ra cổng nào đang cấp nguồn.
  - Danh sách ứng dụng ngốn pin có nút **Thoát** cho ứng dụng thường.
- **Công cụ pin (tab Công cụ pin):**
  - Hiển thị giới hạn sạc gốc của macOS và mở nhanh Cài đặt › Pin để chỉnh.
  - Kịch bản sạc/xả có hướng dẫn từng bước và thông báo: **Hiệu chuẩn pin**, **Xả về ngưỡng**, **Chuẩn bị cất máy (50%)**.
  - Nhắc rút sạc / cắm sạc theo ngưỡng tùy chỉnh và cảnh báo pin nóng.
  - **Bảo vệ nhiệt**: xem tốc độ quạt, đề xuất ứng dụng nên thoát khi pin nóng, hạ ưu tiên ứng dụng nặng
    (chuyển sang lõi tiết kiệm điện) bằng tay hoặc tự động cho các ứng dụng được phép; tự trả lại khi pin nguội hoặc khi thoát BatFlow.
  - Ước tính thời gian dùng theo tải hiện tại, trạng thái Chế độ nguồn điện thấp, ứng dụng đang chặn máy ngủ.
- **Kiến trúc:**
  - 100% Swift, không phụ thuộc Python hay WebKit; mọi số liệu đọc trực tiếp từ IOKit / SMC trên chính máy đang chạy.
  - Không cần quyền quản trị. BatFlow không tự ngắt sạc: giới hạn sạc do macOS thực thi, các kịch bản dựa trên việc bạn cắm/rút sạc theo lời nhắc.
  - Lấy mẫu 1 giây khi đang mở popover/dashboard, 5 giây khi chạy nền.
  - Lưu trữ dữ liệu tại `~/Library/Application Support/BatFlow/`.

---

## 📁 Cấu Trúc Dự Án

```
BatFlow/
├── src/
│   ├── App/                   # main.swift, AppDelegate (menu bar, panel, vòng lấy mẫu)
│   ├── Hardware/              # DeviceInfo (model & cổng), SMC (nhiệt độ), EnergyMonitor, PowerLog
│   ├── Care/                  # BatteryCare (giới hạn sạc, nhắc ngưỡng, kịch bản), ThermalGuard (bảo vệ nhiệt)
│   ├── Models/                # BatteryViewModel, BatteryHistory, UpdateManager
│   ├── Views/                 # PopoverView, DashboardView, ToolsPage, UpdateView, Components/ (Glass, Chart...)
│   └── Windows/               # FloatingPanel, DashboardWindow
├── resources/                 # Info.plist, applet.icns, battery_icon.png
├── scripts/
│   ├── build.sh               # Build & cài vào /Applications (hoặc build ra đường dẫn chỉ định)
│   └── make_dmg.sh            # Đóng gói bộ cài DMG
├── releases/                  # Các bản DMG đã phát hành
└── README.md
```

---

## 🛠️ Hướng Dẫn Biên Dịch & Đóng Gói

Chỉ cần Command Line Tools (`swiftc`); bản build chạy từ macOS 11 trở lên.

### 1. Biên dịch, cài vào /Applications và khởi chạy:
```bash
./scripts/build.sh
```

### 2. Chỉ biên dịch ra một thư mục khác (không đụng bản đang cài):
```bash
./scripts/build.sh /tmp/BatFlow.app
```

### 3. Đóng gói bộ cài đặt DMG (mặc định lấy số phiên bản từ Info.plist):
```bash
./scripts/make_dmg.sh
```

> Lát Intel (x86_64) chỉ được ghép vào khi toolchain còn kèm thư viện Swift cho x86_64; nếu không, script sẽ báo và xuất bản chỉ dành cho Apple Silicon.

---

## 📜 Bản Quyền
© 2026 **Tulie Tech**. All rights reserved.
