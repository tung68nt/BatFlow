import SwiftUI
import AppKit

// MARK: - Modern Menu Row Button Style
struct MenuRowButtonStyle: ButtonStyle {
    var isDestructive: Bool = false
    var isDark: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        configuration.isPressed 
                            ? (isDestructive ? Color(NSColor.systemRed).opacity(isDark ? 0.32 : 0.15) : Color.accentColor.opacity(isDark ? 0.32 : 0.14))
                            : Color.clear
                    )
            )
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .contentShape(Rectangle())
    }
}

// MARK: - Clean Tinted Squircle Action Icon (Light, Airy & Modern)
struct ModernActionIcon: View {
    let systemName: String
    let tintColor: Color
    var isDark: Bool = false
    var size: CGFloat = 22
    var iconSize: CGFloat = 11.5
    var weight: Font.Weight = .semibold

    var body: some View {
        ZStack {
            // 1. Soft Translucent Pastel Tint Background
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tintColor.opacity(isDark ? 0.16 : 0.09))
                .frame(width: size, height: size)

            // 2. Delicate Matching Tinted Border
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(tintColor.opacity(isDark ? 0.30 : 0.22), lineWidth: 0.8)
                .frame(width: size, height: size)

            // 3. Crisp Colored SF Symbol
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: weight))
                .foregroundColor(tintColor)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - About BatFlow View (Apple Native Aesthetic)
struct AboutView: View {
    @ObservedObject var updater = UpdateManager.shared
    @Environment(\.colorScheme) var colorScheme
    var onCheckUpdate: (() -> Void)? = nil
    var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(spacing: 12) {
            // Squircle App Icon
            if let icon = NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 78, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: Color.black.opacity(isDark ? 0.3 : 0.08), radius: 7, x: 0, y: 3)
            }

            VStack(spacing: 3) {
                Text("BatFlow")
                    .font(.system(size: 19, weight: .bold))

                Text("Phiên bản \(updater.currentVersion) (Build \(updater.currentBuild))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.secondary)

                Text("Giải pháp Giám sát Dòng Chảy Năng Lượng & Pin cho macOS")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }

            // Check for Update Button
            Button(action: {
                if let onCheck = onCheckUpdate {
                    onCheck()
                } else {
                    updater.checkForUpdates(userInitiated: true)
                }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Kiểm tra bản cập nhật")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(isDark ? Color.white : Color(white: 0.15))
                .padding(.horizontal, 12)
                .padding(.vertical, 4.5)
                .background(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.06))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.horizontal, 16)
                .padding(.vertical, 2)

            VStack(spacing: 3.5) {
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
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .frame(width: 310, height: 320)
    }
}
