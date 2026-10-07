import SwiftUI
import AppKit

// MARK: - Menu Bar Popover (Liquid Glass panel; the glass itself is supplied by the hosting panel on macOS 26+)
struct BatFiPopoverView: View {
    @ObservedObject var model: BatteryViewModel
    @ObservedObject var updater = UpdateManager.shared
    @ObservedObject var energy = EnergyMonitor.shared
    @ObservedObject var care = BatteryCare.shared
    @ObservedObject var hover = PopoverHover.shared
    @ObservedObject var powerLog = PowerLog.shared
    @Environment(\.colorScheme) var colorScheme
    var onOpenDashboard: () -> Void
    var onOpenTools: () -> Void
    var onCheckUpdate: () -> Void
    var onOpenAbout: () -> Void
    var onQuit: () -> Void

    static let cornerRadius: CGFloat = 22

    var isDark: Bool { colorScheme == .dark }
    var accent: Color { BatPalette.state(model, colorScheme) }
    var colorDivider: Color { Color.primary.opacity(isDark ? 0.14 : 0.10) }

    private var statusText: String {
        if model.isCharging { return "Đang sạc" }
        if model.isExtConnected {
            if let limit = care.nativeLimit, model.currentPct >= limit - 1 { return "Giữ ở \(limit)%" }
            return model.currentPct >= 100 ? "Pin đầy" : "Tạm dừng sạc"
        }
        return "Dùng pin"
    }

    private var etaLabel: String {
        model.isCharging ? "Dự kiến đầy" : (model.isExtConnected ? "Chế độ" : "Dự kiến còn")
    }

    private var etaValue: String {
        if model.isCharging { return model.getEstimatedFullString() }
        if model.isExtConnected { return "Máy chạy bằng nguồn ngoài" }
        return model.getEstimatedEmptyString()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if updater.isUpdateAvailable {
                updateBanner
            }

            header

            VStack(spacing: 6) {
                infoRow(etaLabel, etaValue, valueColor: model.isCharging ? accent : .primary)
                infoRow("Nguồn cấp điện", model.powerSourceStr)
                if !model.isExtConnected, let awake = powerLog.awakeSecondsSinceUnplug(), let unplug = powerLog.lastUnplug {
                    infoRow("Đã chạy từ lúc rút sạc", "\(DashboardFormat.hm(awake)) (rút lúc \(DashboardFormat.shortClock.string(from: unplug.date)))")
                }
                infoRow("Số chu kỳ sạc", "\(model.cycleCount) / \(model.designCycleCount) lần")
                infoRow("Nhiệt độ pin", model.tempC > 0 ? String(format: "%.1f°C", model.tempC) : "—", valueColor: model.tempC >= 38 ? BatPalette.red(colorScheme) : .primary)
                infoRow("Sức khỏe pin", healthText)
                if let limit = care.nativeLimit {
                    infoRow("Giới hạn sạc macOS", "\(limit)%")
                }
            }

            if let kind = care.scenario, let step = care.currentStep {
                Button(action: onOpenTools) {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 11, weight: .semibold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(kind.title) • Bước \(care.stepIndex + 1)/\(care.steps.count)")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(step.title)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isDark ? 0.09 : 0.05), lineWidth: 0.6)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }

            liquidDivider

            BatteryChartView(
                historyPoints: model.historyPoints,
                chartLabels: model.chartLabels,
                isDark: isDark,
                colorLabel: .secondary,
                colorDivider: colorDivider,
                accent: accent
            )

            liquidDivider

            powerWell

            liquidDivider

            appsWell

            liquidDivider

            actions

            HStack(spacing: 4.5) {
                Circle()
                    .fill(BatPalette.green(colorScheme))
                    .frame(width: 4, height: 4)
                Text("Tulie Tech")
                    .font(.system(size: 10, weight: .semibold))
                Text("• BatFlow Realtime")
                    .font(.system(size: 9.5))
                Spacer()
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: 326)
        .background(PanelBackground(cornerRadius: BatFiPopoverView.cornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: BatFiPopoverView.cornerRadius, style: .continuous))
        .ignoresSafeArea()
    }

    private var healthText: String {
        let apple = model.appleHealthPct > 0 ? "\(model.appleHealthPct)% (Apple)" : nil
        let raw = model.rawHealthPct > 0 ? String(format: "%.1f%% (Cell)", model.rawHealthPct) : nil
        let parts = [apple, raw].compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " • ")
    }

    // MARK: Pieces

    private var liquidDivider: some View {
        Rectangle()
            .fill(colorDivider)
            .frame(height: 0.6)
    }

    private var updateBanner: some View {
        Button(action: onCheckUpdate) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Đã có BatFlow v\(updater.latestVersion ?? "")")
                        .font(.system(size: 10.5, weight: .bold))
                    Text("Nhấn để nâng cấp")
                        .font(.system(size: 9.5, weight: .medium))
                        .opacity(0.9)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.05, green: 0.48, blue: 0.98).opacity(isDark ? 0.90 : 0.85),
                        Color(red: 0.0, green: 0.65, blue: 0.85).opacity(isDark ? 0.82 : 0.78)
                    ]),
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(isDark ? 0.25 : 0.35), lineWidth: 0.8)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            BatteryGlyph(pct: model.currentPct, tint: accent, isCharging: model.isCharging)
                .frame(width: 38, height: 19)
            Text("\(model.currentPct)%")
                .font(Font.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: model.isCharging ? "bolt.fill" : (model.isExtConnected ? "pause.fill" : "minus"))
                    .font(.system(size: 9.5, weight: .bold))
                Text(statusText)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(accent.opacity(0.17)))
            .overlay(Capsule().strokeBorder(accent.opacity(0.24), lineWidth: 0.6))
        }
    }

    private func infoRow(_ label: String, _ value: String, valueColor: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
        }
    }

    private var powerWell: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Phân bổ điện năng thời gian thực")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(.secondary)
            VStack(spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text("Máy đang tiêu thụ")
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f W", model.sysLoadW))
                            .font(Font.system(size: 12.5, weight: .semibold).monospacedDigit())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1.5) {
                        Text(model.netWatts > 0.3 ? "Dòng nạp vào pin" : (model.netWatts < -0.3 ? "Dòng xả từ pin" : "Dòng qua pin"))
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)
                        Text(model.netWatts > 0.3 ? String(format: "+%.1f W", model.netWatts) : String(format: "%.1f W", model.netWatts))
                            .font(Font.system(size: 12.5, weight: .semibold).monospacedDigit())
                            .foregroundColor(model.netWatts > 0.3 ? BatPalette.green(colorScheme) : (model.netWatts < -0.3 ? BatPalette.orange(colorScheme) : .primary))
                    }
                }
                HStack {
                    Text("Điện áp & dòng điện")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.2f V • %d mA", model.voltage, model.amperage))
                        .font(Font.system(size: 10.5, weight: .medium).monospacedDigit())
                }
            }
        }
    }

    private var appsWell: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Ứng dụng tiêu thụ năng lượng")
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer()
                Text("Energy Impact")
                    .font(.system(size: 9.5))
            }
            .foregroundColor(.secondary)

            VStack(spacing: 0) {
                if energy.apps.isEmpty {
                    Text(energy.lastUpdated == nil ? "Đang lấy mẫu..." : "Không có ứng dụng gây tốn pin")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                ForEach(energy.apps.prefix(3)) { app in
                    EnergyAppRow(app: app, peak: energy.apps.first?.power ?? 1, showQuit: false, compact: true)
                }
            }
        }
    }

    // Plain menu rows, as in the system's own menu bar panels: monochrome symbol, hover highlight, no boxes
    private var actions: some View {
        VStack(spacing: 1) {
            actionRow("Báo cáo phân tích chi tiết", symbol: "chart.xyaxis.line", badge: "⌘O", action: onOpenDashboard)
            actionRow("Công cụ & kịch bản pin", symbol: "wand.and.stars", badge: nil, action: onOpenTools)
            actionRow("Kiểm tra bản cập nhật", symbol: "arrow.triangle.2.circlepath",
                      badge: updater.isUpdateAvailable ? "Có bản mới" : nil, badgeProminent: true, action: onCheckUpdate)
            actionRow("Giới thiệu BatFlow", symbol: "info.circle", badge: "v\(updater.currentVersion)", action: onOpenAbout)
            actionRow("Thoát BatFlow", symbol: "power", badge: "⌘Q", action: onQuit)
        }
        .padding(.horizontal, -8)
    }

    private func actionRow(_ title: String, symbol: String, badge: String?, badgeProminent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12.5))
                Spacer()
                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 11))
                        .foregroundColor(badgeProminent ? BatPalette.blue(colorScheme) : .secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hover.rowID == title ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { inside in
            if inside { hover.rowID = title } else if hover.rowID == title { hover.rowID = nil }
        }
    }
}

// MARK: - Hover Tracking (shared object: the popover re-renders every second, so per-row state would be lost)
final class PopoverHover: ObservableObject {
    static let shared = PopoverHover()
    @Published var rowID: String?
}

// MARK: - Panel Background
// On macOS 26+ the panel's NSGlassEffectView draws the Liquid Glass, so SwiftUI stays transparent.
struct PanelBackground: View {
    var cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
        } else {
            ZStack {
                VisualEffectView(cornerRadius: cornerRadius)
                if colorScheme == .dark {
                    Color(NSColor.windowBackgroundColor).opacity(0.35)
                } else {
                    Color.white.opacity(0.68)
                }
            }
        }
    }
}
