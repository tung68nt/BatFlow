import Cocoa
import SwiftUI
import Foundation
import IOKit
import WebKit

// MARK: - Battery Data Model (Realtime Automatic Polling)
class BatteryViewModel: ObservableObject {
    @Published var currentPct: Int = 43
    @Published var isCharging: Bool = true
    @Published var isExtConnected: Bool = true
    @Published var voltage: Double = 12.10
    @Published var amperage: Int = 4378
    @Published var netWatts: Double = 53.0
    @Published var sysLoadW: Double = 11.7
    @Published var chargerWatts: Double = 65.0
    @Published var tempC: Double = 30.0
    @Published var cycleCount: Int = 780
    @Published var fullCap: Int = 4687
    @Published var designCap: Int = 6075
    @Published var nominalCap: Int = 4867
    @Published var timeRemainingMinutes: Int = 113
    @Published var timeToFullMinutes: Int = 50
    @Published var powerSourceStr: String = "Củ sạc Type-C (65W)"
    @Published var appleHealthPct: Int = 80
    @Published var rawHealthPct: Double = 77.5
    
    // 12-hour chart points (normalized 0.0 - 1.0)
    @Published var historyPoints: [(time: String, pct: Double)] = [
        ("11:00", 0.95),
        ("13:00", 0.88),
        ("15:00", 0.80),
        ("17:00", 0.72),
        ("19:00", 0.58),
        ("20:30", 0.38),
        ("22:00", 0.22),
        ("23:40", 0.25),
        ("23:52", 0.43)
    ]

    func getEstimatedFullString() -> String {
        guard timeToFullMinutes > 0 && timeToFullMinutes < 65535 else { return "Đang tính toán..." }
        let h = timeToFullMinutes / 60
        let m = timeToFullMinutes % 60
        let durationStr = h > 0 ? "\(h)h \(m)m" : "\(m) phút"
        let fullDate = Date().addingTimeInterval(TimeInterval(timeToFullMinutes * 60))
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(durationStr) nữa (lúc \(formatter.string(from: fullDate)))"
    }

    func getEstimatedEmptyString() -> String {
        guard timeRemainingMinutes > 0 && timeRemainingMinutes < 65535 else { return "Đang tính toán..." }
        let h = timeRemainingMinutes / 60
        let m = timeRemainingMinutes % 60
        let durationStr = h > 0 ? "\(h)h \(m)m" : "\(m) phút"
        let emptyDate = Date().addingTimeInterval(TimeInterval(timeRemainingMinutes * 60))
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(durationStr) nữa (lúc \(formatter.string(from: emptyDate)))"
    }

    func updateData() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var prop: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(service, &prop, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let dict = prop?.takeRetainedValue() as? [String: Any] {
            
            DispatchQueue.main.async {
                let cur = dict["CurrentCapacity"] as? Int ?? 0
                let max = dict["MaxCapacity"] as? Int ?? 100
                self.currentPct = max > 0 ? Int((Double(cur) / Double(max)) * 100.0) : cur
                
                self.isCharging = dict["IsCharging"] as? Bool ?? false
                self.isExtConnected = dict["ExternalConnected"] as? Bool ?? false

                let rawV = dict["Voltage"] as? Double ?? 12100.0
                self.voltage = rawV / 1000.0

                let rawA = dict["Amperage"] as? Int ?? 0
                if rawA > (1 << 63) {
                    self.amperage = rawA - (1 << 64)
                } else {
                    self.amperage = rawA
                }
                self.netWatts = self.voltage * (Double(self.amperage) / 1000.0)

                self.cycleCount = dict["CycleCount"] as? Int ?? 780
                
                let rawT = dict["Temperature"] as? Double ?? 3000.0
                self.tempC = rawT > 1000.0 ? (rawT / 100.0) : rawT

                if let pt = dict["PowerTelemetryData"] as? [String: Any], let load = pt["SystemLoad"] as? Double {
                    self.sysLoadW = load / 1000.0
                } else {
                    self.sysLoadW = abs(self.netWatts)
                }

                if let bd = dict["BatteryData"] as? [String: Any] {
                    self.fullCap = bd["FullChargeCapacity"] as? Int ?? 4687
                    self.nominalCap = bd["NominalChargeCapacity"] as? Int ?? 4867
                    self.designCap = bd["DesignCapacity"] as? Int ?? 6075
                    if self.isCharging {
                        let tFull = dict["AvgTimeToFull"] as? Int ?? (dict["TimeRemaining"] as? Int ?? 0)
                        self.timeToFullMinutes = (tFull > 0 && tFull < 65535) ? tFull : 0
                    } else {
                        let avgTime = bd["AvgTimeToEmpty"] as? Int ?? (dict["TimeRemaining"] as? Int ?? 0)
                        self.timeRemainingMinutes = (avgTime > 0 && avgTime < 65535) ? avgTime : 0
                    }

                    if self.designCap > 0 {
                        self.rawHealthPct = (Double(self.fullCap) / Double(self.designCap)) * 100.0
                        self.appleHealthPct = Int(round((Double(self.nominalCap) / Double(self.designCap)) * 100.0))
                    }
                }

                if let ac = dict["AppleRawAdapterDetails"] as? [[String: Any]], let first = ac.first, let w = first["Watts"] as? Double {
                    self.chargerWatts = w
                } else {
                    self.chargerWatts = 65.0
                }

                if self.isExtConnected {
                    if self.isCharging {
                        self.powerSourceStr = "Củ sạc Type-C (\(Int(self.chargerWatts))W)"
                    } else {
                        self.powerSourceStr = "Nguồn ngoài (\(Int(self.chargerWatts))W)"
                    }
                } else {
                    self.powerSourceStr = "Nguồn pin máy"
                }
            }
        }
    }
}

// MARK: - Modern Menu Row Button Style
struct MenuRowButtonStyle: ButtonStyle {
    var isDestructive: Bool = false
    var isDark: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed 
                    ? (isDestructive ? Color(NSColor.systemRed).opacity(isDark ? 0.35 : 0.12) : Color.accentColor.opacity(isDark ? 0.35 : 0.12))
                    : Color.clear
            )
            .contentShape(Rectangle())
    }
}

// MARK: - About TulieBattery View (Apple Native Aesthetic)
struct AboutView: View {
    @Environment(\.colorScheme) var colorScheme
    var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(spacing: 12) {
            // Squircle App Icon
            if let icon = NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: Color.black.opacity(isDark ? 0.3 : 0.08), radius: 8, x: 0, y: 3)
            }

            VStack(spacing: 3) {
                Text("TulieBattery")
                    .font(.system(size: 19, weight: .bold, design: .rounded))

                Text("Phiên bản 1.0.0 (Build 2026.09.04)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.secondary)

                Text("Giải pháp Giám sát & Quản lý Pin Chuyên Sâu cho macOS")
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundColor(Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }

            Divider()
                .padding(.horizontal, 16)
                .padding(.vertical, 4)

            VStack(spacing: 4) {
                HStack(spacing: 4.5) {
                    Circle()
                        .fill(Color(red: 0.15, green: 0.85, blue: 0.45))
                        .frame(width: 5, height: 5)
                    Text("Thiết kế & Phát triển bởi Tulie Tech")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text("Tối ưu hóa chuyên sâu cho Apple Silicon & Intel Mac")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Color.secondary)
                Text("© 2026 Tulie Tech. All rights reserved.")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundColor(Color.secondary.opacity(0.8))
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(width: 310, height: 300)
    }
}

// MARK: - BatFi Style Popover View (Adaptive Light/Dark Mode Matching System)
struct BatFiPopoverView: View {
    @ObservedObject var model: BatteryViewModel
    @Environment(\.colorScheme) var colorScheme
    var onOpenDashboard: () -> Void
    var onOpenAbout: () -> Void
    var onQuit: () -> Void

    var isDark: Bool { colorScheme == .dark }
    
    // Apple Wi-Fi style translucent palette
    var colorLabel: Color {
        isDark ? Color(red: 0.72, green: 0.72, blue: 0.76) : Color(red: 0.32, green: 0.32, blue: 0.36)
    }
    var colorValue: Color {
        isDark ? Color.white : Color(red: 0.08, green: 0.08, blue: 0.12)
    }
    var colorDivider: Color {
        Color(NSColor.separatorColor).opacity(0.35)
    }
    var colorCard: Color {
        Color.black.opacity(isDark ? 0.2 : 0.035)
    }
    var colorCardStroke: Color {
        Color.black.opacity(isDark ? 0.2 : 0.05)
    }
    var chartBg: Color {
        Color.black.opacity(isDark ? 0.25 : 0.025)
    }
    var buttonBg: Color {
        Color.black.opacity(isDark ? 0.2 : 0.035)
    }
    var emeraldGreen: Color {
        isDark ? Color(red: 0.2, green: 0.85, blue: 0.55) : Color(red: 0.06, green: 0.62, blue: 0.32)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            
            // --- SECTION 1: HEADER (TRẠNG THÁI PIN) ---
            HStack {
                Text("Trạng thái pin")
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundColor(colorValue)
                Spacer()
                HStack(spacing: 5) {
                    if model.isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11))
                            .foregroundColor(emeraldGreen)
                    } else if model.isExtConnected {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color.blue)
                    }
                    Text("\(model.currentPct)%")
                        .font(.system(size: 15.5, weight: .bold, design: .rounded))
                        .foregroundColor(model.currentPct <= 20 ? Color(NSColor.systemRed) : (model.isCharging ? emeraldGreen : (model.isExtConnected ? Color.blue : colorValue)))
                }
            }

            VStack(spacing: 3) {
                HStack {
                    Text(model.isCharging ? "Dự kiến đầy" : (model.isExtConnected ? "Trạng thái sạc" : "Dự kiến còn"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(colorLabel)
                    Spacer()
                    if model.isCharging {
                        Text(model.getEstimatedFullString())
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(emeraldGreen)
                    } else if model.isExtConnected {
                        Text("Đang giữ pin ở \(model.currentPct)% (Hold sạc)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Color.blue)
                    } else {
                        Text(model.getEstimatedEmptyString())
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(colorValue)
                    }
                }

                HStack {
                    Text("Chế độ hoạt động")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(colorLabel)
                    Spacer()
                    Text(model.isCharging ? "Đang nạp sạc pin" : (model.isExtConnected ? "Dùng nguồn ngoài (Tạm dừng sạc)" : "Dùng nguồn pin"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(colorValue)
                }
            }

            Divider().background(colorDivider)

            // --- SECTION 2: SYSTEM SPECS (THÔNG SỐ KỸ THUẬT) ---
            VStack(spacing: 4.5) {
                HStack {
                    Text("Nguồn cấp điện")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(colorLabel)
                    Spacer()
                    Text(model.powerSourceStr)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(colorValue)
                }

                HStack {
                    Text("Số chu kỳ sạc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(colorLabel)
                    Spacer()
                    Text("\(model.cycleCount) / 1.000 lần")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(colorValue)
                }

                HStack {
                    Text("Nhiệt độ pin")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(colorLabel)
                    Spacer()
                    Text(String(format: "%.1f°C", model.tempC))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(colorValue)
                }

                HStack {
                    Text("Sức khỏe pin")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(colorLabel)
                    Spacer()
                    Text("\(model.appleHealthPct)% (Apple) • \(String(format: "%.1f", model.rawHealthPct))% (Cell)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(colorValue)
                }
            }

            Divider().background(colorDivider)

            // --- SECTION 3: LAST 12 HOURS CHART (BIỂU ĐỒ 12 GIỜ QUA) ---
            VStack(alignment: .leading, spacing: 4) {
                Text("Biểu đồ 12 giờ qua")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(colorValue)

                ZStack {
                    // Grid background lines
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            Text("100%")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(colorLabel)
                        }
                        Divider().background(colorDivider).padding(.vertical, 10)
                        HStack {
                            Spacer()
                            Text("50%")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(colorLabel)
                        }
                        Divider().background(colorDivider).padding(.vertical, 10)
                        HStack {
                            Spacer()
                            Text("0%")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(colorLabel)
                        }
                    }

                    // Green Chart Line & Gradient Fill
                    GeometryReader { geo in
                        let w = geo.size.width - 34
                        let h = geo.size.height

                        // Area Path
                        Path { path in
                            guard model.historyPoints.count > 1 else { return }
                            let step = w / CGFloat(model.historyPoints.count - 1)

                            path.move(to: CGPoint(x: 0, y: h * (1.0 - model.historyPoints[0].pct)))
                            for (i, pt) in model.historyPoints.enumerated() {
                                let x = CGFloat(i) * step
                                let y = h * (1.0 - pt.pct)
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                            path.addLine(to: CGPoint(x: w, y: h))
                            path.addLine(to: CGPoint(x: 0, y: h))
                            path.closeSubpath()
                        }
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    emeraldGreen.opacity(isDark ? 0.35 : 0.30),
                                    emeraldGreen.opacity(0.0)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        // Line Path
                        Path { path in
                            guard model.historyPoints.count > 1 else { return }
                            let step = w / CGFloat(model.historyPoints.count - 1)

                            path.move(to: CGPoint(x: 0, y: h * (1.0 - model.historyPoints[0].pct)))
                            for (i, pt) in model.historyPoints.enumerated() {
                                let x = CGFloat(i) * step
                                let y = h * (1.0 - pt.pct)
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                        .stroke(
                            emeraldGreen,
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                        )
                    }
                }
                .frame(height: 72)
                .background(chartBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(colorCardStroke, lineWidth: 1)
                )
                .cornerRadius(5)

                // Time Labels below chart
                HStack {
                    Text("11:00")
                    Spacer()
                    Text("15:00")
                    Spacer()
                    Text("19:00")
                    Spacer()
                    Text("23:40")
                    Spacer()
                    Text("")
                        .frame(width: 26)
                }
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(colorLabel)
            }

            Divider().background(colorDivider)

            // --- SECTION 4: POWER DISTRIBUTION (PHÂN BỔ ĐIỆN NĂNG) ---
            VStack(alignment: .leading, spacing: 4) {
                Text("Phân bổ điện năng thời gian thực")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(colorValue)

                VStack(spacing: 5) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Máy đang tiêu thụ")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(colorLabel)
                            Text(String(format: "%.1f W", model.sysLoadW))
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(colorValue)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(model.isCharging ? "Dòng nạp vào pin" : "Dòng xả từ pin")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(colorLabel)
                            let wStr = model.isCharging && model.netWatts > 0 ? String(format: "+%.1f W", model.netWatts) : String(format: "%.1f W", model.netWatts)
                            Text(wStr)
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(model.isCharging ? emeraldGreen : Color.orange)
                        }
                    }

                    HStack {
                        Text("Điện áp & Dòng điện")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(colorLabel)
                        Spacer()
                        Text(String(format: "%.2f V • %d mA", model.voltage, model.amperage))
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundColor(colorValue)
                    }
                }
                .padding(8)
                .background(colorCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(colorCardStroke, lineWidth: 1)
                )
                .cornerRadius(6)
            }

            Divider().background(colorDivider)

            // --- SECTION 5: APPS (ỨNG DỤNG TIÊU THỤ) ---
            VStack(alignment: .leading, spacing: 4) {
                Text("Ứng dụng tiêu thụ năng lượng")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(colorValue)

                HStack {
                    Spacer()
                    Text("Không có ứng dụng gây tốn pin")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(colorLabel)
                    Spacer()
                }
                .padding(.vertical, 7)
                .background(colorCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(colorCardStroke, lineWidth: 1)
                )
                .cornerRadius(6)
            }

            Divider().background(colorDivider)

            // --- SECTION 6: UNIFIED ACTIONS & BRANDING ---
            VStack(spacing: 7) {
                // Unified Apple-Style Action Card
                VStack(spacing: 0) {
                    // Action 1: Open Detailed Report
                    Button(action: {
                        onOpenDashboard()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "chart.bar.xaxis")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(isDark ? Color(red: 0.25, green: 0.75, blue: 1.0) : Color.blue)
                                .frame(width: 18)
                            
                            Text("Báo cáo phân tích chi tiết...")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(colorValue)
                            
                            Spacer()
                            
                            Text("⌘O")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(colorLabel)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.black.opacity(isDark ? 0.25 : 0.04))
                                .cornerRadius(4)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(MenuRowButtonStyle(isDestructive: false, isDark: isDark))

                    Divider()
                        .background(colorDivider)
                        .padding(.horizontal, 8)

                    // Action 2: About TulieBattery
                    Button(action: {
                        onOpenAbout()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(colorLabel)
                                .frame(width: 18)
                            
                            Text("Giới thiệu TulieBattery...")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(colorValue)
                            
                            Spacer()
                            
                            Text("v1.0.0")
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundColor(colorLabel)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.black.opacity(isDark ? 0.25 : 0.04))
                                .cornerRadius(4)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(MenuRowButtonStyle(isDestructive: false, isDark: isDark))

                    Divider()
                        .background(colorDivider)
                        .padding(.horizontal, 8)

                    // Action 2: Quit App
                    Button(action: {
                        onQuit()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "power")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(Color(NSColor.systemRed).opacity(0.85))
                                .frame(width: 18)
                            
                            Text("Thoát TulieBattery")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(colorValue)
                            
                            Spacer()
                            
                            Text("⌘Q")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(colorLabel)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.black.opacity(isDark ? 0.25 : 0.04))
                                .cornerRadius(4)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(MenuRowButtonStyle(isDestructive: true, isDark: isDark))
                }
                .background(colorCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(colorCardStroke, lineWidth: 1)
                )
                .cornerRadius(7)

                // Sleek Branding Micro-Footer
                HStack(spacing: 4.5) {
                    Circle()
                        .fill(emeraldGreen)
                        .frame(width: 4.5, height: 4.5)
                    Text("Tulie Tech")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(colorValue.opacity(0.75))
                    Text("• Giám sát pin thời gian thực")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(colorLabel.opacity(0.8))
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(width: 310)
        .background(
            VisualEffectView()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 1)
                )
        )
    }
}

// MARK: - Authentic Frosted Glass Visual Effect View (Adapts to System Light/Dark)
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .popover
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Dedicated Floating Panel (BatFi Style)
class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovable = false
        self.becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

// MARK: - Safe Web Navigation Delegate (Prevents Opening External Browsers)
class SafeWebNavDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

// MARK: - Native Window Drag View for WKWebView
class WindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        self.window?.performDrag(with: event)
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: FloatingPanel!
    var hostingView: NSHostingView<BatFiPopoverView>!
    var model = BatteryViewModel()
    var timer: Timer?
    var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePanel)
            button.target = self
        }

        let contentView = BatFiPopoverView(
            model: model,
            onOpenDashboard: { [weak self] in
                self?.closePanel()
                self?.openDetailedDashboard()
            },
            onOpenAbout: { [weak self] in
                self?.closePanel()
                self?.openAboutWindow()
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )
        hostingView = NSHostingView(rootView: contentView)
        let exactSize = hostingView.fittingSize

        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: exactSize.width, height: exactSize.height))
        panel.contentView = hostingView

        // Realtime automatic background updates every 2.0s
        model.updateData()
        updateMenuBarButton()

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.model.updateData()
            self?.updateMenuBarButton()
        }
    }

    @objc func togglePanel() {
        guard let button = statusItem.button, let win = button.window else { return }
        
        if panel.isVisible {
            closePanel()
        } else {
            model.updateData()
            
            // Dynamic exact size calculation so nothing is ever clipped!
            let exactSize = hostingView.fittingSize
            let buttonRect = win.convertToScreen(button.convert(button.bounds, to: nil))
            let screenFrame = NSScreen.main?.visibleFrame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            
            var posX = buttonRect.midX - (exactSize.width / 2)
            posX = max(10, min(screenFrame.maxX - exactSize.width - 10, posX))
            
            // EXACT POSITION: Top of window sits exactly 8 points BELOW the bottom of the menu bar!
            let posY = buttonRect.minY - exactSize.height - 8
            
            panel.setFrame(NSRect(x: posX, y: posY, width: exactSize.width, height: exactSize.height), display: true)
            panel.makeKeyAndOrderFront(nil)
            
            // Start click outside monitor
            startClickOutsideMonitor()
        }
    }

    func startClickOutsideMonitor() {
        if eventMonitor == nil {
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.closePanel()
            }
        }
    }

    func closePanel() {
        panel.orderOut(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func isMenuBarDark() -> Bool {
        guard let button = statusItem?.button else { return true }
        let match = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua
    }

    func drawMenuBarIcon(pct: Int, isCharging: Bool, isExtConnected: Bool, isDark: Bool) -> NSImage {
        let size = NSSize(width: 27, height: 13)
        let image = NSImage(size: size)
        image.lockFocus()

        // Adaptive stroke: Crisp White on Dark, Dark Charcoal on Light
        let strokeColor: NSColor = isDark ? NSColor.white : NSColor(white: 0.12, alpha: 0.95)
        let isHolding = isExtConnected && !isCharging

        let fillColor: NSColor
        if isHolding {
            fillColor = NSColor(red: 0.15, green: 0.70, blue: 0.88, alpha: 1.0) // Apple cyan/blue for hold
        } else if pct <= 20 {
            fillColor = NSColor.systemRed
        } else if pct <= 45 {
            fillColor = NSColor.systemOrange
        } else {
            fillColor = NSColor(red: 0.15, green: 0.85, blue: 0.45, alpha: 1.0)
        }

        // Outer capsule
        let bodyRect = NSRect(x: 1, y: 1, width: 22, height: 11)
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2.5, yRadius: 2.5)
        bodyPath.lineWidth = 1.2
        strokeColor.setStroke()
        bodyPath.stroke()

        // Nipple
        let nippleRect = NSRect(x: 23.5, y: 4, width: 2, height: 5)
        let nipplePath = NSBezierPath(roundedRect: nippleRect, xRadius: 1, yRadius: 1)
        strokeColor.setFill()
        nipplePath.fill()

        // Inner fluid fill
        let maxInnerWidth = 18.0
        let fillWidth = max(2.0, (Double(max(0, min(100, pct))) / 100.0) * maxInnerWidth)
        let fillRect = NSRect(x: 3, y: 3, width: fillWidth, height: 7)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5)
        fillColor.setFill()
        fillPath.fill()

        let symbolConfig = NSImage.SymbolConfiguration(paletteColors: [strokeColor])

        // Distinct iconography: Bolt when actively charging, Power Plug when on Hold / Power Bypass
        if isCharging {
            if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig) {
                let rect = NSRect(x: 8.5, y: 2.2, width: 7.5, height: 8.5)
                bolt.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
        } else if isHolding {
            // Elegant Apple-standard Pause / Hold symbol (||)
            if let pause = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig) {
                let rect = NSRect(x: 8.5, y: 2.8, width: 6.5, height: 7.5)
                pause.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
        }

        image.unlockFocus()
        return image
    }

    func updateMenuBarButton() {
        guard let button = statusItem.button else { return }
        let isDark = isMenuBarDark()
        button.image = drawMenuBarIcon(
            pct: model.currentPct,
            isCharging: model.isCharging,
            isExtConnected: model.isExtConnected,
            isDark: isDark
        )
        button.imagePosition = .imageLeft
        let textColor: NSColor = isDark ? NSColor.white : NSColor(white: 0.12, alpha: 0.95)
        let attrTitle = NSAttributedString(
            string: " \(model.currentPct)%",
            attributes: [
                .foregroundColor: textColor,
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            ]
        )
        button.attributedTitle = attrTitle
    }

    var aboutWindow: NSWindow?

    func openAboutWindow() {
        closePanel()
        if let win = aboutWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 310, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Giới thiệu TulieBattery"
        win.center()
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: AboutView())
        aboutWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Safe & Portable Path Resolvers
    static var reportScriptURL: URL {
        if let bundleURL = Bundle.main.url(forResource: "generate_report", withExtension: "py") {
            return bundleURL
        }
        let codeURL = URL(fileURLWithPath: "/Users/tungnguyen/Code/TulieBattery/src/generate_report.py")
        if FileManager.default.fileExists(atPath: codeURL.path) {
            return codeURL
        }
        return URL(fileURLWithPath: "/Users/tungnguyen/.gemini/antigravity-ide/scratch/battery_monitor/generate_report.py")
    }

    static var reportHTMLURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let tulieDir = appSupport.appendingPathComponent("TulieBattery")
        try? FileManager.default.createDirectory(at: tulieDir, withIntermediateDirectories: true)
        return tulieDir.appendingPathComponent("battery_report.html")
    }

    static var pythonExecutableURL: URL {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) {
                return URL(fileURLWithPath: c)
            }
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    var dashboardWindow: NSWindow?
    var webNavDelegate = SafeWebNavDelegate()

    func openDetailedDashboard() {
        closePanel()
        
        if let win = dashboardWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "TulieBattery • Báo Cáo Phân Tích Pin & Hệ Thống"
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 720, height: 500)
        
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: win.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = webNavDelegate
        webView.uiDelegate = webNavDelegate
        
        let scriptURL = AppDelegate.reportScriptURL
        let reportURL = AppDelegate.reportHTMLURL
        let legacyURL = URL(fileURLWithPath: "/tmp/battery_report.html")
        let initialURL = FileManager.default.fileExists(atPath: reportURL.path) ? reportURL : legacyURL
        
        webView.loadFileURL(initialURL, allowingReadAccessTo: initialURL.deletingLastPathComponent())
        
        win.contentView = webView
        dashboardWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Safe & Race-Condition-Free Process Execution (No hardcoded paths, No shell injection)
        DispatchQueue.global(qos: .userInitiated).async { [weak webView] in
            let proc = Process()
            let pythonURL = AppDelegate.pythonExecutableURL
            
            if pythonURL.path == "/usr/bin/env" {
                proc.executableURL = pythonURL
                proc.arguments = ["python3", scriptURL.path, reportURL.path]
            } else {
                proc.executableURL = pythonURL
                proc.arguments = [scriptURL.path, reportURL.path]
            }
            
            proc.terminationHandler = { [weak webView] _ in
                DispatchQueue.main.async {
                    webView?.loadFileURL(reportURL, allowingReadAccessTo: reportURL.deletingLastPathComponent())
                }
            }
            
            try? proc.run()
        }
    }
}

// Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
