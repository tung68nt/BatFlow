import SwiftUI
import AppKit

struct UpdateView: View {
    @ObservedObject var updater = UpdateManager.shared
    @Environment(\.colorScheme) var colorScheme
    var onClose: () -> Void

    var isDark: Bool { colorScheme == .dark }

    var cardBg: Color {
        isDark ? Color(white: 0.14) : Color(white: 0.95)
    }

    var cardStroke: Color {
        isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.08)
    }

    var textPrimary: Color {
        isDark ? Color.white : Color(white: 0.1)
    }

    var textSecondary: Color {
        isDark ? Color(white: 0.65) : Color(white: 0.45)
    }

    var accentBlue: Color {
        Color(red: 0.05, green: 0.52, blue: 1.0)
    }

    var emeraldGreen: Color {
        Color(red: 0.15, green: 0.85, blue: 0.45)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header: App Icon & Title
            HStack(spacing: 14) {
                if let icon = NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: Color.black.opacity(isDark ? 0.35 : 0.12), radius: 5, x: 0, y: 2)
                }

                VStack(alignment: .leading, spacing: 2.5) {
                    Text("Cập nhật phần mềm BatFlow")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(textPrimary)

                    Text("Phiên bản hiện tại: v\(updater.currentVersion) (Build \(updater.currentBuild))")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(textSecondary)
                }

                Spacer()
            }
            .padding(.top, 4)

            Divider()

            // State-driven Content Body
            Group {
                switch updater.status {
                case .idle, .checking:
                    VStack(spacing: 14) {
                        Spacer()
                        ProgressView()
                            .scaleEffect(0.9)
                        Text("Đang kiểm tra bản phát hành mới...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(textSecondary)
                        Spacer()
                    }
                    .frame(height: 170)

                case .upToDate(let version):
                    VStack(spacing: 9) {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 38))
                            .foregroundColor(emeraldGreen)
                        
                        Text("Bạn đang dùng phiên bản mới nhất!")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(textPrimary)

                        Text("BatFlow v\(version) hiện là phiên bản cập nhật nhất. Không có bản cập nhật nào khả dụng vào lúc này.")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)

                        HStack(spacing: 4.5) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 9.5))
                            Text("Kiểm tra lần cuối: \(updater.lastCheckedFormatted)")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(textSecondary.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3.5)
                        .background(cardBg)
                        .cornerRadius(6)
                        .padding(.top, 4)

                        Spacer()
                    }
                    .frame(height: 170)

                case .updateAvailable(let version, let title, let notes, _, let size):
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Phiên bản mới khả dụng: v\(version)")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(accentBlue)
                                    
                                    Text("NEW")
                                        .font(.system(size: 8.5, weight: .heavy))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(accentBlue)
                                        .clipShape(Capsule())
                                }

                                if !title.isEmpty && title != "BatFlow v\(version)" {
                                    Text(title)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundColor(textPrimary)
                                }
                            }

                            Spacer()

                            if size > 0 {
                                let mb = Double(size) / (1024.0 * 1024.0)
                                Text(String(format: "%.1f MB", mb))
                                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                    .foregroundColor(textSecondary)
                            }
                        }

                        // Release Notes Card
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Nội dung cập nhật:")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(textSecondary)

                            ScrollView {
                                Text(notes)
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundColor(textPrimary)
                                    .lineSpacing(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(height: 100)
                            .background(cardBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(cardStroke, lineWidth: 1)
                            )
                            .cornerRadius(6)
                        }
                    }
                    .frame(height: 170)

                case .downloading(let progress, let received, let total):
                    VStack(spacing: 14) {
                        Spacer()
                        VStack(spacing: 8) {
                            HStack {
                                Text("Đang tải bản cài đặt...")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(textPrimary)
                                Spacer()
                                Text("\(Int(progress * 100))%")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundColor(accentBlue)
                            }

                            ProgressView(value: progress, total: 1.0)
                                .accentColor(accentBlue)

                            HStack {
                                let recMB = Double(received) / (1024.0 * 1024.0)
                                let totMB = Double(total) / (1024.0 * 1024.0)
                                Text(String(format: "%.1f MB / %.1f MB", recMB, totMB))
                                    .font(.system(size: 10, weight: .regular, design: .rounded))
                                    .foregroundColor(textSecondary)
                                Spacer()
                            }
                        }
                        .padding(12)
                        .background(cardBg)
                        .cornerRadius(8)
                        Spacer()
                    }
                    .frame(height: 170)

                case .readyToInstall:
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "arrow.down.app.fill")
                            .font(.system(size: 38))
                            .foregroundColor(accentBlue)

                        Text("Tải hoàn tất! Sẵn sàng nâng cấp.")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(textPrimary)

                        Text("Nhấn 'Cài đặt và Khởi động lại' để ứng dụng tự động nâng cấp bản mới nhất mà không mất cấu hình.")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                    }
                    .frame(height: 170)

                case .installing:
                    VStack(spacing: 14) {
                        Spacer()
                        ProgressView()
                            .scaleEffect(0.9)
                        Text("Đang cài đặt và cấu hình BatFlow...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(textPrimary)
                        Spacer()
                    }
                    .frame(height: 170)

                case .error(let msg):
                    VStack(spacing: 10) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 34))
                            .foregroundColor(.orange)

                        Text("Không thể kiểm tra cập nhật")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(textPrimary)

                        Text(msg)
                            .font(.system(size: 10.5, weight: .regular))
                            .foregroundColor(textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 10)
                        Spacer()
                    }
                    .frame(height: 170)
                }
            }

            Divider()

            // Footer Action Buttons
            HStack(spacing: 10) {
                if case .updateAvailable = updater.status {
                    Button(action: {
                        if let u = URL(string: "https://github.com/\(updater.githubRepo)/releases") {
                            NSWorkspace.shared.open(u)
                        }
                    }) {
                        Text("Xem trên Web")
                            .font(.system(size: 11, weight: .regular))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(textSecondary)

                    Spacer()

                    Button(action: {
                        onClose()
                    }) {
                        Text("Để sau")
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(cardBg)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        updater.startDownload()
                    }) {
                        Text("Cập nhật ngay")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(accentBlue)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                } else if case .downloading = updater.status {
                    Spacer()
                    Button(action: {
                        updater.cancelDownload()
                    }) {
                        Text("Hủy tải về")
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(cardBg)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                } else if case .readyToInstall = updater.status {
                    Spacer()
                    Button(action: {
                        onClose()
                    }) {
                        Text("Đóng")
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(cardBg)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        updater.installAndRelaunch()
                    }) {
                        Text("Cài đặt & Khởi động lại")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(emeraldGreen)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                } else {
                    if case .upToDate = updater.status {
                        Button(action: {
                            updater.resetAndCheck()
                        }) {
                            HStack(spacing: 4.5) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Kiểm tra lại")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundColor(textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5.5)
                            .background(cardBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(cardStroke, lineWidth: 1)
                            )
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    } else if case .error = updater.status {
                        Button(action: {
                            updater.resetAndCheck()
                        }) {
                            HStack(spacing: 4.5) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Thử lại")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundColor(textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5.5)
                            .background(cardBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(cardStroke, lineWidth: 1)
                            )
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    Button(action: {
                        onClose()
                    }) {
                        Text("Đóng")
                            .font(.system(size: 12, weight: .medium))
                            .frame(minWidth: 76)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(cardBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(cardStroke, lineWidth: 1)
                            )
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .frame(width: 420, height: 360)
    }
}
