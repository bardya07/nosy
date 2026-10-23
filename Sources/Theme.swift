import SwiftUI
import AppKit

// Hamstr's palette, type and motion, shared by every Nosy window.
enum Theme {
    static let background = dynamic(light: 0xFFFDF8, dark: 0x16110B)
    static let surface = dynamic(light: 0xF7F0E1, dark: 0x221B13)
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x2B2319)
    static let line = dynamic(light: 0xEADFC9, dark: 0x3A3024)
    static let ink = dynamic(light: 0x211B14, dark: 0xF7F0E1)
    static let muted = dynamic(light: 0x6D5F4B, dark: 0x9B8D75)
    static let faint = dynamic(light: 0x9B8D75, dark: 0x6D5F4B)
    // Nosy's accent is the hamster's orange; Hamstr coral marks recording and problems.
    static let accent = dynamic(light: 0xE5843A, dark: 0xEE9A52)
    static let coral = dynamic(light: 0xF0617A, dark: 0xF2738A)
    static let amber = dynamic(light: 0xE9A23A, dark: 0xEDB056)
    static let green = dynamic(light: 0x4FA97F, dark: 0x5FB98E)
    // Dark text on the orange accent: white on orange fails contrast (~2.7:1).
    static let onAccent = Color(nsColor: NSColor(srgbRed: 0x21 / 255, green: 0x1B / 255, blue: 0x14 / 255, alpha: 1))
    // Orange for text and icons on cream, darkened in light mode to stay readable.
    static let accentText = dynamic(light: 0xA9561A, dark: 0xF0A563)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light)
        })
    }
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    // Bundled Hamstr fonts, falling back to the system font if they're missing.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        NSFont(name: "Bricolage Grotesque", size: size) != nil
            ? .custom("Bricolage Grotesque", fixedSize: size).weight(weight)
            : .system(size: size, weight: weight, design: .rounded)
    }
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        NSFont(name: "Hanken Grotesk", size: size) != nil
            ? .custom("Hanken Grotesk", fixedSize: size).weight(weight)
            : .system(size: size, weight: weight)
    }
    static let label = text(10.5, .semibold)
}

enum Motion {
    static let press = Animation.easeOut(duration: 0.16)
    static let hover = Animation.easeOut(duration: 0.15)
    // Hamstr's springy settle, kept subtle.
    static let state = Animation.spring(duration: 0.38, bounce: 0.16)
    static func state(_ reduce: Bool) -> Animation { reduce ? .easeOut(duration: 0.18) : state }
}

// Every pressable surface: lifts slightly on hover, presses to 0.97, shows a focus ring.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, dark, quiet }
    var kind: Kind = .primary
    var tint: Color = Theme.accent
    var height: CGFloat = 44
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, style: self)
    }
    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let style: PillButtonStyle
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(Theme.text(style.height > 36 ? 15 : 13, .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, style.height > 36 ? 20 : 14)
                .frame(maxWidth: style.fullWidth ? .infinity : nil)
                .frame(height: style.height)
                .background {
                    Capsule().fill(background)
                    // A rounded rect, not Capsule: stroked capsules draw stray end caps on narrow pills.
                    if style.kind == .quiet {
                        RoundedRectangle(cornerRadius: style.height / 2, style: .circular).strokeBorder(Theme.line, lineWidth: 1)
                    }
                }
                .modifier(Lift(active: style.kind != .quiet, hovering: hovering && enabled && !configuration.isPressed, color: shadowColor))
                .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Capsule())
                .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
                .animation(Motion.press, value: configuration.isPressed)
        }
        private var background: Color {
            switch style.kind {
            case .primary: style.tint
            case .dark: Theme.ink
            case .quiet: hovering && enabled ? Theme.surface : Theme.raised
            }
        }
        private var foreground: Color {
            switch style.kind {
            case .primary: Theme.onAccent
            case .dark: Theme.background
            case .quiet: Theme.ink
            }
        }
        private var shadowColor: Color {
            guard enabled, style.kind != .quiet else { return .clear }
            return (style.kind == .primary ? style.tint : Color.black).opacity(hovering ? 0.28 : 0.16)
        }
    }
}

// Filled pills brighten and lift on hover; quiet ones only change fill (filters would clip their outline).
private struct Lift: ViewModifier {
    let active: Bool
    let hovering: Bool
    let color: Color
    func body(content: Content) -> some View {
        if active {
            content.brightness(hovering ? 0.04 : 0).shadow(color: color, radius: hovering ? 10 : 6, y: hovering ? 4 : 2)
        } else {
            content
        }
    }
}

// Round icon button (pause/resume, small actions).
struct RoundButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    func makeBody(configuration: Configuration) -> some View { RoundBody(configuration: configuration, size: size) }
    private struct RoundBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: size, height: size)
                .background(hovering && enabled ? Theme.surface : Theme.raised, in: Circle())
                .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
                .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.94 : 1)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Circle())
                .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

// Inline text action ("Show in Finder"): underline appears on hover.
struct LinkButtonStyle: ButtonStyle {
    var tint: Color = Theme.accentText
    func makeBody(configuration: Configuration) -> some View { LinkBody(configuration: configuration, tint: tint) }
    private struct LinkBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(Theme.text(12.5, .semibold))
                .foregroundStyle(tint)
                .underline(hovering)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .onHover { hovering = $0 }
        }
    }
}

// Text fields and the lecture menu: border warms on hover, turns accent when focused.
struct FieldChrome: ViewModifier {
    var focused = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .font(Theme.text(14, .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(border, lineWidth: focused ? 1.5 : 1))
            .shadow(color: Theme.accent.opacity(focused ? 0.18 : 0), radius: 6)
            .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
            .animation(Motion.hover, value: focused)
    }
    private var border: Color {
        if focused { return Theme.accent.opacity(0.85) }
        return hovering && enabled ? Theme.faint : Theme.line
    }
}

// Small round icon button for the header (folder, microphone).
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var active = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, size: size, active: active, destructive: destructive)
    }
    private struct IconBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let active: Bool
        let destructive: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(hovering && destructive ? Theme.coral : (active || hovering ? Theme.accentText : Theme.muted))
                .frame(width: size, height: size)
                .background(hovering && enabled ? (destructive ? Theme.coral.opacity(0.14) : Theme.surface) : .clear, in: Circle())
                .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.9 : 1)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Circle())
                .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

extension View {
    func fieldChrome(focused: Bool = false) -> some View { modifier(FieldChrome(focused: focused)) }
    func card(_ fill: Color = Theme.surface, radius: CGFloat = 16) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// Crossfade with a hint of blur and scale, so swapping states reads as one object changing.
extension AnyTransition {
    static func soft(_ reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .modifier(active: SoftModifier(amount: 1), identity: SoftModifier(amount: 0))
    }
}
private struct SoftModifier: ViewModifier {
    let amount: Double
    func body(content: Content) -> some View {
        content.opacity(1 - amount).blur(radius: 3 * amount).scaleEffect(1 - 0.03 * amount)
    }
}

// Quick hover label. The first one waits a beat so passing the mouse over doesn't flash it;
// once one has shown, neighbours appear instantly (no delay, no animation).
@MainActor
private enum TipClock {
    static var lastHidden = Date.distantPast
    static var warm: Bool { Date().timeIntervalSince(lastHidden) < 0.8 }
}

struct Tip: ViewModifier {
    let text: String
    var edge: VerticalEdge = .bottom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                if inside {
                    if TipClock.warm || reduceMotion { shown = true; return }
                    pending = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.14)) { shown = true }
                    }
                } else if shown {
                    TipClock.lastHidden = Date()
                    shown = false
                }
            }
            .overlay(alignment: edge == .bottom ? .bottom : .top) {
                if shown {
                    Text(text)
                        .font(Theme.text(11.5, .semibold))
                        .foregroundStyle(Theme.background)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .frame(maxWidth: 190)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        .fixedSize()
                        .alignmentGuide(edge == .bottom ? .bottom : .top) { $0[edge == .bottom ? .top : .bottom] + (edge == .bottom ? -7 : 7) }
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: edge == .bottom ? .top : .bottom)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .zIndex(shown ? 100 : 0)
    }
}

extension View {
    func tip(_ text: String, edge: VerticalEdge = .bottom) -> some View { modifier(Tip(text: text, edge: edge)) }
}
