import SwiftUI
import AppKit
import UserNotifications

// MARK: - Battery Tools Page
struct ToolsPage: View {
    @ObservedObject var model: BatteryViewModel
    @ObservedObject var energy: EnergyMonitor
    @ObservedObject var care: BatteryCare
    @ObservedObject var thermal = ThermalGuard.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            limitSection
            scenarioSection
            alertSection
            thermalSection
            runtimeSection
        }
        .onAppear { care.refreshNativeLimit(force: true) }
    }

    // MARK: Charge limit

    private var limitSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Giới hạn sạc", caption: "Giữ pin dưới 100% là cách kéo dài tuổi thọ hiệu quả nhất")
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.10), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: CGFloat(care.effectiveLimit) / 100.0)
                        .stroke(BatPalette.green(colorScheme), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(care.effectiveLimit)%")
                        .font(Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                }
                .frame(width: 74, height: 74)

                VStack(alignment: .leading, spacing: 4) {
                    Text(limitTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(limitDetail)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Button("Mở Cài đặt Pin") { BatteryCare.openBatterySettings() }
            }
            .padding(18)
            .contentCard()
        }
    }

    private var limitTitle: String {
        if let limit = care.nativeLimit { return "macOS đang giới hạn sạc ở \(limit)%" }
        return care.nativeLimitSupported ? "Chưa đặt giới hạn sạc" : "Pin đang được sạc tới 100%"
    }

    private var limitDetail: String {
        if care.nativeLimit != nil {
            return "Giới hạn do firmware thực thi nên vẫn có hiệu lực khi máy ngủ hoặc tắt. Đổi mức trong Cài đặt › Pin › Sạc. Muốn sạc đầy một lần, chọn “Sạc đầy ngay” trong menu pin của macOS."
        }
        if care.nativeLimitSupported {
            return "Máy này hỗ trợ giới hạn sạc gốc của macOS (80–100%). Nếu thường xuyên cắm sạc, đặt 80% trong Cài đặt › Pin › Sạc sẽ giảm đáng kể tốc độ chai pin."
        }
        return "Phiên bản macOS này chưa có giới hạn sạc tùy chỉnh. Bật “Sạc pin được tối ưu hóa” trong Cài đặt › Pin và dùng nhắc ngưỡng bên dưới để chủ động rút sạc."
    }

    // MARK: Scenarios

    private var scenarioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Kịch bản sạc / xả", caption: "BatFlow theo dõi mức pin và nhắc bạn từng bước")
            if let kind = care.scenario {
                activeScenario(kind)
            } else {
                Group {
                    HStack(alignment: .top, spacing: 14) {
                        scenarioCard(.calibration, symbol: "gauge", summary: "Sạc đầy → giữ 60 phút → xả về 15% → sạc đầy lại. Giúp máy đo lại dung lượng thật khi phần trăm pin nhảy hoặc sụt bất thường. Chỉ nên làm vài tháng một lần.")
                        scenarioCard(.drainToLimit, symbol: "arrow.down.to.line", summary: "Khi pin đang cao hơn mức giới hạn (ví dụ vừa sạc đầy), rút sạc và nhận thông báo đúng lúc pin về ngưỡng để cắm lại.")
                        scenarioCard(.storage, symbol: "shippingbox", summary: "Đưa pin về 50% trước khi cất máy lâu ngày. Đây là mức Apple khuyến nghị để pin ít lão hóa nhất khi không dùng.")
                    }
                }
            }
        }
    }

    private func scenarioCard(_ kind: CareScenarioKind, symbol: String, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(BatPalette.blue(colorScheme))
                Text(kind.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(summary)
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Bắt đầu") { care.start(kind, model: model) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .contentCard()
    }

    private func activeScenario(_ kind: CareScenarioKind) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(kind.title) • Bước \(care.stepIndex + 1)/\(care.steps.count)")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button("Dừng kịch bản") { care.cancelScenario() }
            }
            ForEach(Array(care.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: index < care.stepIndex ? "checkmark.circle.fill" : (index == care.stepIndex ? "largecircle.fill.circle" : "circle"))
                        .font(.system(size: 14))
                        .foregroundColor(index < care.stepIndex ? BatPalette.green(colorScheme) : (index == care.stepIndex ? BatPalette.blue(colorScheme) : .secondary))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title)
                            .font(.system(size: 12.5, weight: index == care.stepIndex ? .semibold : .regular))
                            .foregroundColor(index > care.stepIndex ? .secondary : .primary)
                        if index == care.stepIndex {
                            Text(step.instruction)
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let needsPower = step.needsPower, needsPower != model.isExtConnected {
                                Text(needsPower ? "Đang chờ bạn cắm sạc" : "Đang chờ bạn rút sạc")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(BatPalette.orange(colorScheme))
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.10))
                                    Capsule().fill(BatPalette.blue(colorScheme))
                                        .frame(width: max(4, geo.size.width * CGFloat(care.stepProgress(model))))
                                }
                            }
                            .frame(height: 5)
                            .padding(.top, 2)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(18)
        .contentCard()
    }

    // MARK: Alerts

    private var alertSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Nhắc ngưỡng & nhiệt độ", caption: "Thông báo để chủ động cắm / rút sạc đúng lúc")
            VStack(alignment: .leading, spacing: 14) {
                toggleRow(title: "Nhắc khi pin chạm ngưỡng", detail: "Giữ pin trong khoảng 20–80% giúp giảm hao mòn hóa học",
                          isOn: Binding(get: { care.alertsEnabled }, set: { newValue in
                              care.alertsEnabled = newValue
                              if newValue { requestNotifications() }
                          }))

                if care.alertsEnabled {
                    thresholdSlider(title: "Nhắc rút sạc khi đạt", value: Binding(get: { Double(care.alertHigh) }, set: { care.alertHigh = Int($0) }), range: 60...100, suffix: "%")
                    thresholdSlider(title: "Nhắc cắm sạc khi còn", value: Binding(get: { Double(care.alertLow) }, set: { care.alertLow = Int($0) }), range: 5...40, suffix: "%")
                    if let limit = care.nativeLimit, care.alertHigh > limit {
                        Text("macOS đã dừng sạc ở \(limit)% nên lời nhắc rút sạc ở \(care.alertHigh)% sẽ không xuất hiện.")
                            .font(.system(size: 11))
                            .foregroundColor(BatPalette.orange(colorScheme))
                    }
                }

                Divider()

                toggleRow(title: "Cảnh báo pin nóng",
                          detail: model.tempC > 0 ? String(format: "Nhiệt độ hiện tại %.1f°C. Sạc khi pin nóng làm pin chai nhanh hơn nhiều.", model.tempC) : "Máy này không công bố cảm biến nhiệt độ pin.",
                          isOn: Binding(get: { care.heatAlertEnabled }, set: { newValue in
                              care.heatAlertEnabled = newValue
                              if newValue { requestNotifications() }
                          }))

                if care.heatAlertEnabled {
                    thresholdSlider(title: "Cảnh báo từ", value: Binding(get: { Double(care.heatThreshold) }, set: { care.heatThreshold = Int($0) }), range: 33...45, suffix: "°C")
                }
            }
            .padding(18)
            .contentCard()
        }
    }

    private func toggleRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .toggleStyle(SwitchToggleStyle())
                .labelsHidden()
        }
    }

    private func thresholdSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 150, alignment: .leading)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue))\(suffix)")
                .font(Font.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Thermal guard

    private var thermalSection: some View {
        let candidates = energy.apps.filter { ThermalGuard.canManage($0) }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Bảo vệ nhiệt", caption: "Giảm tải để hạ nhiệt độ pin, không cần quyền quản trị")
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    StatTile(label: "Nhiệt độ pin", value: model.tempC > 0 ? String(format: "%.1f", model.tempC) : "—", unit: model.tempC > 0 ? "°C" : "",
                             sub: thermal.isHot ? "Đang vượt ngưỡng \(care.heatThreshold)°C" : "Ngưỡng bảo vệ \(care.heatThreshold)°C",
                             valueColor: thermal.isHot ? BatPalette.red(colorScheme) : .primary)
                    if thermal.fans.isEmpty {
                        StatTile(label: "Quạt", value: "Không có", sub: "Máy tản nhiệt thụ động, giảm tải là cách duy nhất")
                    } else {
                        ForEach(Array(thermal.fans.enumerated()), id: \.offset) { index, fan in
                            StatTile(label: thermal.fans.count > 1 ? "Quạt \(index + 1)" : "Quạt", value: String(format: "%.0f", fan.rpm), unit: "vòng/phút",
                                     sub: String(format: "%.0f%% công suất • tối đa %.0f", fan.load * 100, fan.maxRPM))
                        }
                    }
                }

                Divider()

                toggleRow(title: "Bật bảo vệ nhiệt",
                          detail: "Khi pin vượt ngưỡng nhiệt, BatFlow báo ứng dụng đang ngốn nhất để bạn thoát hoặc hạ ưu tiên. Ngưỡng dùng chung với cảnh báo pin nóng ở trên.",
                          isOn: Binding(get: { thermal.enabled }, set: { newValue in
                              thermal.enabled = newValue
                              if newValue { requestNotifications() }
                          }))

                if thermal.enabled {
                    toggleRow(title: "Tự hạ ưu tiên ứng dụng được phép",
                              detail: "Ứng dụng được đánh dấu bên dưới sẽ tự chuyển sang lõi tiết kiệm điện khi pin nóng và được trả lại khi pin nguội 3°C dưới ngưỡng.",
                              isOn: Binding(get: { thermal.autoThrottle }, set: { thermal.autoThrottle = $0 }))
                }

                Divider()

                Text("Ứng dụng đang chạy nặng")
                    .font(.system(size: 12.5, weight: .medium))
                if candidates.isEmpty {
                    Text(energy.lastUpdated == nil ? "Đang lấy mẫu mức tiêu thụ..." : "Không có ứng dụng nào đang tiêu thụ đáng kể.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }
                ForEach(candidates) { app in
                    HStack(spacing: 10) {
                        Group {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable()
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                                .font(.system(size: 12, weight: .medium))
                            Text(thermal.isThrottled(app) ? "Đang chạy ở ưu tiên nền" : String(format: "Energy Impact %.1f", app.power))
                                .font(.system(size: 10.5))
                                .foregroundColor(thermal.isThrottled(app) ? BatPalette.blue(colorScheme) : .secondary)
                        }
                        Spacer()
                        if thermal.enabled {
                            Toggle("Cho phép tự hạ", isOn: Binding(get: { thermal.allowedApps.contains(app.name) }, set: { allowed in
                                if allowed { thermal.allowedApps.insert(app.name) } else { thermal.allowedApps.remove(app.name) }
                            }))
                            .toggleStyle(CheckboxToggleStyle())
                            .font(.system(size: 11))
                        }
                        Button(thermal.isThrottled(app) ? "Khôi phục" : "Hạ ưu tiên") {
                            if thermal.isThrottled(app) { thermal.restore(appNamed: app.name) } else { thermal.throttle(app) }
                        }
                        .frame(width: 96)
                    }
                }
                ForEach(thermal.throttled.keys.sorted().filter { name in !candidates.contains { $0.name == name } }, id: \.self) { name in
                    HStack {
                        Text(name)
                            .font(.system(size: 12, weight: .medium))
                        Text("Đang chạy ở ưu tiên nền")
                            .font(.system(size: 10.5))
                            .foregroundColor(BatPalette.blue(colorScheme))
                        Spacer()
                        Button("Khôi phục") { thermal.restore(appNamed: name) }
                            .frame(width: 96)
                    }
                }
            }
            .padding(18)
            .contentCard()
        }
    }

    // MARK: Runtime

    private var remainingWh: Double {
        return Double(model.remainingCap) * model.voltage / 1000.0
    }

    private var runtimeEstimate: String {
        guard model.sysLoadW > 0.5, remainingWh > 0 else { return "—" }
        let hours = remainingWh / model.sysLoadW
        return String(format: "%dh %02dm", Int(hours), Int((hours - floor(hours)) * 60))
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Tăng thời gian dùng pin", caption: "Những thứ đang rút pin nhanh hơn mức cần thiết")
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    StatTile(label: "Năng lượng còn trong pin", value: remainingWh > 0 ? String(format: "%.1f", remainingWh) : "—", unit: "Wh",
                             sub: "\(model.remainingCap) mAh ở \(String(format: "%.2f", model.voltage)) V")
                    StatTile(label: "Dùng được với tải hiện tại", value: runtimeEstimate, sub: String(format: "Nếu giữ mức %.1f W", model.sysLoadW))
                    StatTile(label: "Chế độ nguồn điện thấp", value: care.lowPowerMode ? "Đang bật" : "Đang tắt",
                             sub: care.lowPowerMode ? "Giảm xung CPU và độ sáng" : "Bật để kéo dài thời gian dùng",
                             valueColor: care.lowPowerMode ? BatPalette.green(colorScheme) : .primary)
                }

                if !care.lowPowerMode {
                    HStack {
                        Text("Bật Chế độ nguồn điện thấp trong Cài đặt › Pin để giảm công suất tiêu thụ khi dùng pin.")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Mở Cài đặt Pin") { BatteryCare.openBatterySettings() }
                    }
                }

                Divider()

                Text("Ứng dụng đang chặn máy ngủ")
                    .font(.system(size: 12.5, weight: .medium))
                if energy.sleepBlockers.isEmpty {
                    Text("Không có ứng dụng nào ngăn máy hoặc màn hình ngủ.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }
                ForEach(energy.sleepBlockers) { blocker in
                    HStack(spacing: 10) {
                        Image(systemName: blocker.kind.contains("màn hình") ? "sun.max" : "moon.zzz")
                            .font(.system(size: 12))
                            .foregroundColor(BatPalette.orange(colorScheme))
                            .frame(width: 20)
                        Text(blocker.processName)
                            .font(.system(size: 12, weight: .medium))
                        Text(blocker.kind)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(blocker.reason)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 320, alignment: .trailing)
                    }
                }

                if let top = energy.apps.first, top.power >= 20 {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "flame.fill")
                            .foregroundColor(BatPalette.orange(colorScheme))
                        Text("\(top.name) đang tiêu thụ nhiều nhất (Energy Impact \(String(format: "%.0f", top.power))). Thoát ứng dụng này ở tab Tổng quan nếu chưa cần dùng.")
                            .font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(18)
            .contentCard()
        }
    }
}
