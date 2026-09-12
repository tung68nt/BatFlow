import SwiftUI
import AppKit

// MARK: - BatFi Style Popover View (Adaptive Light/Dark Mode Matching System)
struct BatFiPopoverView: View {
    @ObservedObject var model: BatteryViewModel
    @ObservedObject var updater = UpdateManager.shared
    @Environment(\.colorScheme) var colorScheme
    var onOpenDashboard: () -> Void
    var onCheckUpdate: () -> Void
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
        isDark ? Color.white.opacity(0.12) : Color(NSColor.separatorColor).opacity(0.35)
    }
    var colorCard: Color {
        isDark ? Color.white.opacity(0.08) : Color.white.opacity(0.65)
    }
    var colorCardStroke: Color {
        isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.06)
    }
    var chartBg: Color {
        isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.55)
    }
    var buttonBg: Color {
        isDark ? Color.white.opacity(0.08) : Color.white.opacity(0.65)
    }
    var emeraldGreen: Color {
        isDark ? Color(red: 0.2, green: 0.85, blue: 0.55) : Color(red: 0.06, green: 0.62, blue: 0.32)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8.5) {
            
            // --- UPDATE NOTIFICATION BANNER (AUTO SCAN DETECTED) ---
            if updater.isUpdateAvailable {
                Button(action: {
                    onCheckUpdate()
                }) {
                    HStack(spacing: 7.5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Đã có bản cập nhật BatFlow v\(updater.latestVersion ?? "")!")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(.white)
                            Text("Nâng cấp ngay để có trải nghiệm tốt nhất")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(Color.white.opacity(0.92))
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.05, green: 0.48, blue: 0.98), Color(red: 0.0, green: 0.65, blue: 0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(7)
                }
                .buttonStyle(.plain)
            }

            // --- SECTION 1: HEADER (TRẠNG THÁI PIN) ---
            HStack {
                Text("Trạng thái pin")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(colorValue)
                Spacer()
                HStack(spacing: 4.5) {
                    if model.isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10.5))
                            .foregroundColor(emeraldGreen)
                    } else if model.isExtConnected {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 10.5))
                            .foregroundColor(Color.blue)
                    }
                    Text("\(model.currentPct)%")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(model.currentPct <= 20 ? Color(NSColor.systemRed) : (model.isCharging ? emeraldGreen : (model.isExtConnected ? Color.blue : colorValue)))
                }
            }

            VStack(spacing: 5.5) {
                HStack {
                    Text(model.isCharging ? "Dự kiến đầy" : (model.isExtConnected ? "Trạng thái sạc" : "Dự kiến còn"))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(colorLabel)
                    Spacer()
                    if model.isCharging {
                        Text(model.getEstimatedFullString())
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(emeraldGreen)
                    } else if model.isExtConnected {
                        Text("Đang giữ pin ở \(model.currentPct)% (Hold sạc)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.blue)
                    } else {
                        Text(model.getEstimatedEmptyString())
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(colorValue)
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("Chế độ hoạt động")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(colorLabel)
                    Spacer()
                    Text(model.isCharging ? "Đang nạp sạc pin" : (model.isExtConnected ? "Dùng nguồn ngoài\n(Tạm dừng sạc)" : "Dùng nguồn pin"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(colorValue)
                        .multilineTextAlignment(.trailing)
                }
            }

            Divider().background(colorDivider)

            // --- SECTION 2: SYSTEM SPECS (THÔNG SỐ KỸ THUẬT) ---
            VStack(spacing: 6) {
                HStack {
                    Text("Nguồn cấp điện")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(colorLabel)
                    Spacer()
                    Text(model.powerSourceStr)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(colorValue)
                }

                HStack {
                    Text("Số chu kỳ sạc")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(colorLabel)
                    Spacer()
                    Text("\(model.cycleCount) / 1.000 lần")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(colorValue)
                }

                HStack {
                    Text("Nhiệt độ pin")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(colorLabel)
                    Spacer()
                    Text(String(format: "%.1f°C", model.tempC))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(colorValue)
                }

                HStack {
                    Text("Sức khỏe pin")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(colorLabel)
                    Spacer()
                    Text("\(model.appleHealthPct)% (Apple) • \(String(format: "%.1f", model.rawHealthPct))% (Cell)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(colorValue)
                }
            }

            Divider().background(colorDivider)

            // --- SECTION 3: LAST 12 HOURS CHART (BIỂU ĐỒ 12 GIỜ QUA) ---
            BatteryChartView(
                historyPoints: model.historyPoints,
                chartLabels: model.chartLabels,
                isDark: isDark,
                colorLabel: colorLabel,
                colorDivider: colorDivider,
                colorCardStroke: colorCardStroke,
                chartBg: chartBg,
                emeraldGreen: emeraldGreen
            )

            Divider().background(colorDivider)

            // --- SECTION 4: POWER DISTRIBUTION (PHÂN BỔ ĐIỆN NĂNG) ---
            VStack(alignment: .leading, spacing: 4.5) {
                Text("Phân bổ điện năng thời gian thực")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(colorLabel)

                VStack(spacing: 5.5) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text("Máy đang tiêu thụ")
                                .font(.system(size: 9.5, weight: .regular))
                                .foregroundColor(colorLabel)
                            Text(String(format: "%.1f W", model.sysLoadW))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(colorValue)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1.5) {
                            Text(model.isCharging ? "Dòng nạp vào pin" : "Dòng xả từ pin")
                                .font(.system(size: 9.5, weight: .regular))
                                .foregroundColor(colorLabel)
                            let wStr = model.isCharging && model.netWatts > 0 ? String(format: "+%.1f W", model.netWatts) : String(format: "%.1f W", model.netWatts)
                            Text(wStr)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(model.isCharging ? emeraldGreen : Color.orange)
                        }
                    }

                    HStack {
                        Text("Điện áp & Dòng điện")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(colorLabel)
                        Spacer()
                        Text(String(format: "%.2f V • %d mA", model.voltage, model.amperage))
                            .font(.system(size: 10.5, weight: .medium))
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
            VStack(alignment: .leading, spacing: 4.5) {
                Text("Ứng dụng tiêu thụ năng lượng")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(colorLabel)

                HStack {
                    Spacer()
                    Text("Không có ứng dụng gây tốn pin")
                        .font(.system(size: 10.5, weight: .regular))
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
                        HStack(spacing: 9) {
                            ModernActionIcon(
                                systemName: "chart.xyaxis.line",
                                tintColor: isDark ? Color(red: 0.35, green: 0.75, blue: 1.0) : Color(red: 0.05, green: 0.52, blue: 1.0),
                                isDark: isDark,
                                iconSize: 11,
                                weight: .semibold
                            )
                            
                            Text("Báo cáo phân tích chi tiết")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(colorValue)
                            
                            Spacer()
                            
                            Text("⌘O")
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .foregroundColor(colorLabel)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.05))
                                .cornerRadius(4)
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 3.6)
                    }
                    .buttonStyle(MenuRowButtonStyle(isDestructive: false, isDark: isDark))

                    Rectangle()
                        .fill(colorDivider)
                        .frame(height: 0.8)
                        .padding(.leading, 39)
                        .padding(.trailing, 8)

                    // Action 2: Check for Updates
                    Button(action: {
                        onCheckUpdate()
                    }) {
                        HStack(spacing: 9) {
                            ModernActionIcon(
                                systemName: "arrow.triangle.2.circlepath",
                                tintColor: isDark ? Color(red: 0.38, green: 0.85, blue: 0.72) : Color(red: 0.08, green: 0.65, blue: 0.52),
                                isDark: isDark,
                                iconSize: 11,
                                weight: .semibold
                            )
                            
                            Text("Kiểm tra bản cập nhật")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(colorValue)
                            
                            Spacer()
                            
                            if updater.isUpdateAvailable {
                                Text("CÓ BẢN MỚI")
                                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color(red: 0.05, green: 0.52, blue: 1.0))
                                    .cornerRadius(4)
                            }
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 8)
                        .padding(.vertical, 3.6)
                    }
                    .buttonStyle(MenuRowButtonStyle(isDestructive: false, isDark: isDark))

                    Rectangle()
                        .fill(colorDivider)
                        .frame(height: 0.8)
                        .padding(.leading, 39)
                        .padding(.trailing, 8)

                    // Action 3: About BatFlow
                    Button(action: {
                        onOpenAbout()
                    }) {
                        HStack(spacing: 9) {
                            ModernActionIcon(
                                systemName: "info.circle",
                                tintColor: isDark ? Color(red: 0.32, green: 0.78, blue: 1.0) : Color(red: 0.08, green: 0.60, blue: 0.96),
                                isDark: isDark,
                                iconSize: 11.5,
                                weight: .medium
                            )
                            
                            Text("Giới thiệu BatFlow")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(colorValue)
                            
                            Spacer()
                            
                            Text("v\(updater.currentVersion)")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(colorLabel)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.05))
                                .cornerRadius(4)
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 8)
                        .padding(.vertical, 3.6)
                    }
                    .buttonStyle(MenuRowButtonStyle(isDestructive: false, isDark: isDark))

                    Rectangle()
                        .fill(colorDivider)
                        .frame(height: 0.8)
                        .padding(.leading, 39)
                        .padding(.trailing, 8)

                    // Action 3: Quit App
                    Button(action: {
                        onQuit()
                    }) {
                        HStack(spacing: 9) {
                            ModernActionIcon(
                                systemName: "power",
                                tintColor: isDark ? Color(red: 1.0, green: 0.38, blue: 0.42) : Color(red: 0.95, green: 0.24, blue: 0.26),
                                isDark: isDark,
                                iconSize: 11,
                                weight: .semibold
                            )
                            
                            Text("Thoát BatFlow")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(colorValue)
                            
                            Spacer()
                            
                            Text("⌘Q")
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .foregroundColor(colorLabel)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.05))
                                .cornerRadius(4)
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 8)
                        .padding(.top, 3.6)
                        .padding(.bottom, 8)
                    }
                    .buttonStyle(MenuRowButtonStyle(isDestructive: true, isDark: isDark))
                }
                .background(colorCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(colorCardStroke, lineWidth: 1)
                )
                .cornerRadius(8)

                // Sleek Branding Micro-Footer
                HStack(spacing: 4.5) {
                    Circle()
                        .fill(emeraldGreen)
                        .frame(width: 4, height: 4)
                    Text("Tulie Tech")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(colorValue.opacity(0.75))
                    Text("• BatFlow Realtime")
                        .font(.system(size: 9.5, weight: .regular))
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
            ZStack {
                VisualEffectView(cornerRadius: 14)
                if isDark {
                    Color(NSColor.windowBackgroundColor).opacity(0.35)
                } else {
                    Color.white.opacity(0.68)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .ignoresSafeArea()
    }
}
