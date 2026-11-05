import AppKit
import SwiftUI

/// Pacer's palette: warm paper canvas, white cards, big tightly tracked type.
/// Steered text and moved sliders take the accent; Muse Wonder's scores use slack/hot.
enum Theme {
    static let canvas = Color(light: 0xF7F5F3, dark: 0x141414)
    static let card = Color(light: 0xFFFFFF, dark: 0x212020)
    static let ink = Color(light: 0x0D0D0D, dark: 0xFFFFFF)
    static let muted = Color(light: 0x85807B, dark: 0xA39E99)
    static let hairline = Color(light: 0xE4E1DD, dark: 0x323131)
    static let hot = Color(light: 0xD92D20, dark: 0xFF6B5E)
    static let slack = Color(light: 0x039855, dark: 0x3DD68C)
    static let accent = Color(light: 0x0A84FF, dark: 0x3B8BFF)
    static let quietWash = Color.primary.opacity(0.07)

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold)
    }
}
extension View {
    /// Display type: semibold and tightly tracked, after Cosmos.
    func display(_ size: CGFloat) -> some View {
        font(Theme.display(size)).tracking(-size * 0.035)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .foregroundStyle(prominent ? .white : Theme.ink)
            .background(prominent ? Theme.accent : Theme.quietWash, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}
