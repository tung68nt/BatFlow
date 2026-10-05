import SwiftUI
import AppKit

// MARK: - Dashboard Root (native SwiftUI; page switching lives in the window toolbar)
struct DashboardView: View {
    @ObservedObject var model: BatteryViewModel
    @ObservedObject var energy = EnergyMonitor.shared
    @ObservedObject var powerLog = PowerLog.shared
    @ObservedObject var care = BatteryCare.shared
    @ObservedObject var router = DashboardRouter.shared
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var clock = LiveClock.shared

    private var now: Date { clock.now }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if router.page == 0 {
                    OverviewPage(model: model, energy: energy, powerLog: powerLog, care: care, now: now)
                } else {
                    ToolsPage(model: model, energy: energy, care: care)
                }
                footer
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 500)
        .onAppear { clock.start() }
        .onDisappear { clock.stop() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            BatteryGlyph(pct: model.currentPct, tint: BatPalette.state(model, colorScheme), isCharging: model.isCharging)
                .frame(width: 46, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(DeviceInfo.shared.modelName)
                    .font(.system(size: 19, weight: .semibold))
                Text("\(DeviceInfo.shared.specString) • \(DeviceInfo.shared.modelIdentifier)")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Circle().fill(BatPalette.green(colorScheme)).frame(width: 5, height: 5)
            Text("BatFlow • Tulie Tech")
                .font(.system(size: 11, weight: .medium))
            Spacer()
            Text("Dữ liệu phần cứng trực tiếp • \(DashboardFormat.clock.string(from: now))")
                .font(.system(size: 11))
        }
        .foregroundColor(.secondary)
        .padding(.top, 4)
    }
}

// MARK: - Live Clock (one-second ticker that only runs while the dashboard is on screen)
final class LiveClock: ObservableObject {
    static let shared = LiveClock()
    @Published var now = Date()
    private var timer: Timer?

    func start() {
        now = Date()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Formatting Helpers
enum DashboardFormat {
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static let eventTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm"
        return f
    }()

    static let shortClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func hm(_ seconds: Int) -> String {
        return seconds >= 3600 ? String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60) : "\(max(0, seconds) / 60) phút"
    }

    static func hms(_ seconds: Int) -> String {
        return String(format: "%dh %02dm %02ds", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    static func watts(_ value: Double) -> String {
        return String(format: "%.1f", value)
    }
}

// MARK: - Battery Glyph
struct BatteryGlyph: View {
    var pct: Int
    var tint: Color
    var isCharging: Bool

    var body: some View {
        GeometryReader { geo in
            let bodyWidth = geo.size.width - 4
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: geo.size.height * 0.28, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.6)
                    .frame(width: bodyWidth)
                RoundedRectangle(cornerRadius: geo.size.height * 0.16, style: .continuous)
                    .fill(tint)
                    .frame(width: max(4, (bodyWidth - 6) * CGFloat(max(0, min(100, pct))) / 100.0), height: geo.size.height - 6)
                    .padding(.leading, 3)
                if isCharging {
                    // Text-coloured bolt with a background-coloured halo: readable over both the fill and the empty part
                    Image(systemName: "bolt.fill")
                        .font(.system(size: geo.size.height * 0.66, weight: .heavy))
                        .foregroundColor(.primary)
                        .shadow(color: Color(NSColor.windowBackgroundColor), radius: 0.6)
                        .shadow(color: Color(NSColor.windowBackgroundColor), radius: 0.6)
                        .frame(width: bodyWidth)
                }
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 2.6, height: geo.size.height * 0.36)
                    .offset(x: bodyWidth + 1.2)
            }
        }
    }
}

// MARK: - Section Header
struct SectionHeader: View {
    var title: String
    var caption: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 14.5, weight: .semibold))
            Spacer()
            Text(caption)
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Stat Tile
struct StatTile: View {
    var label: String
    var value: String
    var unit: String = ""
    var sub: String
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Font.system(size: 19, weight: .semibold).monospacedDigit())
                    .foregroundColor(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            Text(sub)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Overview Page
struct OverviewPage: View {
    @ObservedObject var model: BatteryViewModel
    @ObservedObject var energy: EnergyMonitor
    @ObservedObject var powerLog: PowerLog
    @ObservedObject var care: BatteryCare
    var now: Date
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { BatPalette.state(model, colorScheme) }

    private var statusText: String {
        if !model.hasBattery { return "Không tìm thấy pin" }
        if model.isCharging { return "Đang sạc pin" }
        if model.isExtConnected {
            if model.isFullyCharged || model.currentPct >= 100 { return "Nguồn ngoài • Pin đầy" }
            if let limit = care.nativeLimit, model.currentPct >= limit - 1 { return "Nguồn ngoài • Giữ ở giới hạn \(limit)%" }
            return "Nguồn ngoài • Tạm dừng sạc"
        }
        return "Đang dùng pin"
    }

    private var statusIcon: String {
        model.isCharging ? "bolt.fill" : (model.isExtConnected ? "pause.fill" : "battery.100")
    }

    private var etaTitle: String {
        model.isCharging ? "Dự kiến đầy" : (model.isExtConnected ? "Trạng thái" : "Dự kiến còn")
    }

    private var etaValue: String {
        if model.isCharging { return model.getEstimatedFullString() }
        if model.isExtConnected { return "Máy chạy bằng nguồn ngoài" }
        return model.getEstimatedEmptyString()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            hero
            powerSection
            portSection
            healthSection
            appsSection
            timelineSection
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(model.currentPct)%")
                        .font(Font.system(size: 54, weight: .semibold, design: .rounded).monospacedDigit())
                    HStack(spacing: 6) {
                        Image(systemName: statusIcon)
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(statusText)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(Capsule().fill(accent.opacity(0.16)))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(etaTitle)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                    Text(etaValue)
                        .font(.system(size: 15, weight: .medium))
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(LinearGradient(gradient: Gradient(colors: [accent.opacity(0.75), accent]), startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, geo.size.width * CGFloat(model.currentPct) / 100.0))
                    if let limit = care.nativeLimit {
                        Rectangle()
                            .fill(Color.primary.opacity(0.55))
                            .frame(width: 1.5, height: 14)
                            .offset(x: geo.size.width * CGFloat(limit) / 100.0)
                    }
                }
            }
            .frame(height: 8)

            HStack(alignment: .top, spacing: 16) {
                StatTile(label: "Màn hình sáng đợt này", value: DashboardFormat.hms(powerLog.liveSessionSeconds(now: now)),
                         sub: powerLog.sessionStart.map { "Từ \(DashboardFormat.clock.string(from: $0))" } ?? "Đang đọc nhật ký nguồn")
                StatTile(label: "Tổng màn hình sáng hôm nay", value: DashboardFormat.hms(powerLog.liveScreenSeconds(now: now)), sub: "Tích lũy từ 00:00")
                StatTile(label: "Máy đang tiêu thụ", value: DashboardFormat.watts(model.sysLoadW), unit: "W",
                         sub: String(format: "Pin %.2f V • %d mA", model.voltage, model.amperage))
                awakeTile
                StatTile(label: "Nhiệt độ pin", value: model.tempC > 0 ? String(format: "%.1f", model.tempC) : "—", unit: model.tempC > 0 ? "°C" : "",
                         sub: model.tempC <= 0 ? "Máy không công bố cảm biến" : (model.tempC >= 38 ? "Nóng, nên giảm tải" : (model.tempC >= 35 ? "Hơi ấm" : "Bình thường")),
                         valueColor: model.tempC >= 38 ? BatPalette.red(colorScheme) : .primary)
            }
        }
        .padding(22)
        .contentCard()
    }

    /// Awake time on battery since the charger was last pulled (sleep excluded).
    private var awakeTile: some View {
        Group {
            if !model.isExtConnected, let awake = powerLog.awakeSecondsSinceUnplug(now: now), let unplug = powerLog.lastUnplug {
                StatTile(label: "Đã chạy từ lúc rút sạc", value: DashboardFormat.hms(awake), sub: awakeDetail(unplug))
            } else {
                StatTile(label: "Đã chạy từ lúc rút sạc", value: "—",
                         sub: model.isExtConnected ? "Đang cắm sạc" : "Đang đọc nhật ký nguồn")
            }
        }
    }

    private func awakeDetail(_ unplug: (date: Date, pct: Int?)) -> String {
        let time = DashboardFormat.eventTime.string(from: unplug.date)
        guard let pct = unplug.pct, pct >= model.currentPct else { return "Rút lúc \(time) • không tính lúc ngủ" }
        return "Rút lúc \(time) ở \(pct)% • đã dùng \(pct - model.currentPct)%"
    }

    // MARK: Power flow

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Phân bổ điện năng & nguồn sạc", caption: "Dòng nạp, công suất adapter và tải của máy")
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(accent.opacity(0.18))
                        Image(systemName: model.isExtConnected ? "powerplug.fill" : "battery.100")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(accent)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(connectionTitle)
                            .font(.system(size: 13, weight: .semibold))
                        Text(connectionDetail)
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                HStack(alignment: .top, spacing: 16) {
                    if model.isExtConnected {
                        StatTile(label: "Công suất củ sạc", value: model.chargerWatts > 0 ? String(format: "%.0f", model.chargerWatts) : "—", unit: model.chargerWatts > 0 ? "W" : "",
                                 sub: model.adapterVoltage > 0 ? String(format: "Hợp đồng %.0f V • %.2f A", model.adapterVoltage, model.adapterCurrent) : "Công suất định danh adapter")
                    } else {
                        StatTile(label: "Trạng thái nguồn", value: "Dùng pin", sub: "Không có củ sạc kết nối", valueColor: BatPalette.orange(colorScheme))
                    }
                    StatTile(label: "Máy đang tiêu thụ", value: DashboardFormat.watts(model.sysLoadW), unit: "W", sub: "Tải phần cứng hệ thống")
                    StatTile(label: batteryFlowLabel, value: batteryFlowValue, unit: "W", sub: batteryFlowDetail, valueColor: batteryFlowColor)
                }

                if model.isExtConnected && model.chargerWatts > 0 {
                    flowMeter
                }

                if let warning = weakChargerWarning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(BatPalette.orange(colorScheme))
                        Text(warning)
                            .font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .insetWell(cornerRadius: 10)
                }
            }
            .padding(18)
            .contentCard()
        }
    }

    private var connectionTitle: String {
        guard model.isExtConnected else { return "Đang sử dụng pin tích hợp" }
        if let port = model.powerPort { return "Đang nhận nguồn qua \(port.title)" }
        return "Đang nhận nguồn ngoài"
    }

    private var connectionDetail: String {
        guard model.isExtConnected else { return "Chưa cắm sạc • Thiết bị đang xả pin" }
        let protocolName = model.powerPort?.kind == .magsafe ? "Sạc từ tính MagSafe" : "USB Power Delivery"
        return model.chargerWatts > 0 ? "\(protocolName) • Adapter \(Int(model.chargerWatts.rounded())) W" : protocolName
    }

    private var batteryFlowLabel: String {
        model.netWatts > 0.3 ? "Dòng nạp vào pin" : (model.netWatts < -0.3 ? "Dòng xả từ pin" : "Dòng qua pin")
    }

    private var batteryFlowValue: String {
        model.netWatts > 0.3 ? String(format: "+%.1f", model.netWatts) : String(format: "%.1f", model.netWatts)
    }

    private var batteryFlowDetail: String {
        if model.netWatts > 0.3 { return "Đang nạp năng lượng" }
        if model.netWatts < -0.3 { return model.isExtConnected ? "Pin đang xả bù cho adapter" : "Xả năng lượng thực tế" }
        return model.isExtConnected ? "Pin nghỉ, máy dùng thẳng adapter" : "Gần như không tải"
    }

    private var batteryFlowColor: Color {
        if model.netWatts > 0.3 { return BatPalette.green(colorScheme) }
        if model.netWatts < -0.3 { return BatPalette.orange(colorScheme) }
        return BatPalette.blue(colorScheme)
    }

    private var weakChargerWarning: String? {
        guard model.isExtConnected, model.chargerWatts > 0, model.netWatts < -1.0, model.sysLoadW > model.chargerWatts else { return nil }
        return String(format: "Củ sạc %.0f W nhỏ hơn mức máy đang dùng (%.1f W), pin phải bù %.1f W. Hãy dùng củ sạc công suất lớn hơn hoặc giảm tải.",
                      model.chargerWatts, model.sysLoadW, abs(model.netWatts))
    }

    private var flowMeter: some View {
        let total = max(model.chargerWatts, model.sysLoadW + max(0, model.netWatts), 1)
        let sysShare = CGFloat(min(1, model.sysLoadW / total))
        let batShare = CGFloat(min(1 - Double(sysShare), max(0, model.netWatts) / total))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                legendDot(BatPalette.blue(colorScheme), String(format: "Máy dùng %.1f W", model.sysLoadW))
                legendDot(BatPalette.green(colorScheme), String(format: "Nạp pin %.1f W", max(0, model.netWatts)))
                legendDot(Color.primary.opacity(0.18), "Dư công suất")
                Spacer()
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule().fill(BatPalette.blue(colorScheme)).frame(width: max(3, geo.size.width * sysShare))
                    if batShare > 0.005 {
                        Capsule().fill(BatPalette.green(colorScheme)).frame(width: max(3, geo.size.width * batShare))
                    }
                    Capsule().fill(Color.primary.opacity(0.12))
                }
            }
            .frame(height: 8)
        }
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: Ports

    private var portSection: some View {
        let left = model.ports.filter { $0.side == .left }
        let right = model.ports.filter { $0.side == .right }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Sơ đồ cổng trên máy", caption: "Đọc trực tiếp từ bộ điều khiển cổng của \(DeviceInfo.shared.modelName)")
            Group {
                HStack(alignment: .top, spacing: 14) {
                    portPanel(title: "Cạnh trái", ports: left)
                    portPanel(title: "Cạnh phải", ports: right)
                }
            }
        }
    }

    private func portPanel(title: String, ports: [HardwarePort]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(ports.filter { $0.canCharge }.count) cổng nhận sạc")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            }
            if ports.isEmpty {
                Text("Không có cổng")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(ports) { port in
                PortChip(port: port, watts: model.chargerWatts, isCharging: model.isCharging, accent: accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentCard()
    }

    // MARK: Health

    private var healthSection: some View {
        let cycleShare = model.designCycleCount > 0 ? min(1.0, Double(model.cycleCount) / Double(model.designCycleCount)) : 0
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Sức khỏe pin", caption: "Đối chiếu số liệu Apple công bố và đo thô từ cell")
            HStack(alignment: .top, spacing: 16) {
                StatTile(label: "Dung lượng tối đa (Apple)", value: model.appleHealthPct > 0 ? "\(model.appleHealthPct)" : "—", unit: "%",
                         sub: "Giống Cài đặt › Pin")
                StatTile(label: "Đo thô từ cell", value: model.rawHealthPct > 0 ? String(format: "%.1f", model.rawHealthPct) : "—", unit: "%",
                         sub: model.designCap > 0 ? "\(model.nominalCap > 0 ? model.nominalCap : model.fullCap) / \(model.designCap) mAh" : "Chưa có số liệu")
                VStack(alignment: .leading, spacing: 6) {
                    StatTile(label: "Chu kỳ sạc", value: "\(model.cycleCount)", unit: "/ \(model.designCycleCount)", sub: "Thiết kế giữ ~80% dung lượng tới mức này")
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.10))
                            Capsule()
                                .fill(cycleShare > 0.85 ? BatPalette.orange(colorScheme) : BatPalette.green(colorScheme))
                                .frame(width: max(4, geo.size.width * CGFloat(cycleShare)))
                        }
                    }
                    .frame(height: 5)
                }
                StatTile(label: "Dung lượng còn lại", value: model.remainingCap > 0 ? "\(model.remainingCap)" : "—", unit: "mAh",
                         sub: model.fullCap > 0 ? "Đầy hiện tại \(model.fullCap) mAh" : "Chưa có số liệu")
            }
            .padding(18)
            .contentCard()
        }
    }

    // MARK: Apps

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Ứng dụng tiêu thụ năng lượng", caption: "Xếp theo chỉ số Energy Impact của macOS")
            VStack(spacing: 0) {
                if energy.apps.isEmpty {
                    Text(energy.lastUpdated == nil ? "Đang lấy mẫu mức tiêu thụ..." : "Không có ứng dụng nào tiêu thụ đáng kể")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                }
                ForEach(Array(energy.apps.enumerated()), id: \.element.id) { index, app in
                    EnergyAppRow(app: app, peak: energy.apps.first?.power ?? 1, showQuit: true)
                    if index < energy.apps.count - 1 {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentCard()
        }
    }

    // MARK: Timeline

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Nhật ký nguồn gần đây", caption: "Sự kiện cắm/rút sạc, ngủ và thức từ nhật ký hệ thống")
            VStack(alignment: .leading, spacing: 10) {
                if powerLog.events.isEmpty {
                    Text(powerLog.loadedAt == nil ? "Đang đọc nhật ký nguồn..." : "Chưa có sự kiện nào trong 36 giờ qua")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                ForEach(powerLog.events) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Text(DashboardFormat.eventTime.string(from: event.date))
                            .font(Font.system(size: 11).monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 78, alignment: .trailing)
                        Circle()
                            .fill(color(for: event.kind))
                            .frame(width: 7, height: 7)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.system(size: 12.5, weight: .medium))
                            Text(event.detail)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(18)
            .contentCard()
        }
    }

    private func color(for kind: PowerEvent.Kind) -> Color {
        switch kind {
        case .displayOn: return BatPalette.green(colorScheme)
        case .displayOff: return Color.secondary
        case .sleep: return Color.purple
        case .wake, .unplugged: return BatPalette.orange(colorScheme)
        case .plugged: return BatPalette.blue(colorScheme)
        }
    }
}

// MARK: - Port Chip
struct PortChip: View {
    var port: HardwarePort
    var watts: Double
    var isCharging: Bool
    var accent: Color
    @Environment(\.colorScheme) private var colorScheme

    private var symbol: String {
        switch port.kind {
        case .magsafe: return "bolt.fill"
        case .usbc, .thunderbolt2: return "cable.connector"
        case .hdmi: return "tv"
        case .sdcard: return "sdcard"
        case .audio: return "headphones"
        case .usba: return "externaldrive"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(port.isPowerSource ? accent : .secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(port.isPowerSource ? accent.opacity(0.18) : Color.primary.opacity(0.06)))

            VStack(alignment: .leading, spacing: 1.5) {
                Text(port.title)
                    .font(.system(size: 12.5, weight: .medium))
                Text(port.spec)
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)

            if port.isPowerSource {
                Text(watts > 0 ? "\(isCharging ? "Đang sạc" : "Cấp nguồn") \(Int(watts.rounded())) W" : "Cấp nguồn")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(accent.opacity(0.16)))
            } else if port.isConnected {
                Text("Có thiết bị")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .insetWell(cornerRadius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(port.isPowerSource ? accent.opacity(0.55) : Color.clear, lineWidth: 1.2)
        )
    }
}

// MARK: - Energy App Row
struct EnergyAppRow: View {
    var app: EnergyApp
    var peak: Double
    var showQuit: Bool
    var compact: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    private var level: (text: String, color: Color) {
        if app.power >= 40 { return ("Cao", BatPalette.red(colorScheme)) }
        if app.power >= 12 { return ("Vừa", BatPalette.orange(colorScheme)) }
        return ("Thấp", BatPalette.green(colorScheme))
    }

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: compact ? 10 : 13))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: compact ? 18 : 28, height: compact ? 18 : 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: compact ? 11 : 12.5, weight: .medium))
                    .lineLimit(1)
                if !compact {
                    Text("\(app.category) • \(app.processCount) tiến trình • CPU \(String(format: "%.1f", app.cpu))%")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)

            if !compact {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.09))
                        Capsule().fill(level.color).frame(width: max(3, geo.size.width * CGFloat(min(1, app.power / max(peak, 1)))))
                    }
                }
                .frame(width: 90, height: 5)
            }

            Text(String(format: "%.1f", app.power))
                .font(Font.system(size: compact ? 11 : 12.5, weight: .semibold).monospacedDigit())
                .foregroundColor(level.color)
                .frame(width: compact ? 38 : 48, alignment: .trailing)

            if showQuit {
                if let running = app.runningApp, running.bundleIdentifier != Bundle.main.bundleIdentifier {
                    Button("Thoát") {
                        running.terminate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { EnergyMonitor.shared.sample() }
                    }
                    .frame(width: 62)
                    .help("Yêu cầu \(app.name) thoát để tiết kiệm pin")
                } else {
                    Color.clear.frame(width: 62, height: 1)
                }
            }
        }
        .padding(.vertical, compact ? 3 : 8)
    }
}
