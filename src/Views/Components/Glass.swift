import SwiftUI
import AppKit

// MARK: - Content Card
// Content sits on opaque, standard surfaces. Liquid Glass is reserved for the control layer that floats above
// content (the window toolbar and the menu bar panel), which the system draws itself.
struct ContentCard: ViewModifier {
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 0.7)
            )
    }
}

// MARK: - Inset Well (content grouping that sits on top of glass without stacking a second glass layer)
struct InsetWell: ViewModifier {
    var cornerRadius: CGFloat = 12
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.05), lineWidth: 0.7)
            )
    }
}

extension View {
    func contentCard(cornerRadius: CGFloat = 14) -> some View {
        modifier(ContentCard(cornerRadius: cornerRadius))
    }

    func insetWell(cornerRadius: CGFloat = 12) -> some View {
        modifier(InsetWell(cornerRadius: cornerRadius))
    }
}

// MARK: - Shared Palette
enum BatPalette {
    static func green(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.20, green: 0.85, blue: 0.55) : Color(red: 0.06, green: 0.62, blue: 0.32)
    }
    static func blue(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.25, green: 0.62, blue: 1.0) : Color(red: 0.0, green: 0.44, blue: 0.92)
    }
    static func orange(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 1.0, green: 0.62, blue: 0.04) : Color(red: 0.86, green: 0.47, blue: 0.0)
    }
    static func red(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 1.0, green: 0.27, blue: 0.23) : Color(red: 0.84, green: 0.16, blue: 0.14)
    }

    /// Accent for the current power state: charging, holding on adapter, or discharging.
    static func state(_ model: BatteryViewModel, _ scheme: ColorScheme) -> Color {
        if model.currentPct <= 20 && !model.isExtConnected { return red(scheme) }
        if model.isCharging { return green(scheme) }
        if model.isExtConnected { return blue(scheme) }
        return orange(scheme)
    }
}
