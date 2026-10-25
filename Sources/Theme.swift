import SwiftUI
import AppKit

// Design E: native glass, navy type, green primary actions and a blue Stop.
enum Theme {
    static let background = dynamic(light: 0xFFFFFF, dark: 0x0B1C2B, lightAlpha: 0.60, darkAlpha: 0.88)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x173449, lightAlpha: 0.60, darkAlpha: 0.78)
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x24475E, lightAlpha: 0.75, darkAlpha: 0.90)
    static let line = dynamic(light: 0x0B4466, dark: 0x9FD5F1, lightAlpha: 0.10, darkAlpha: 0.13)
    static let panelBorder = dynamic(light: 0xFFFFFF, dark: 0xABDDF3, lightAlpha: 0.90, darkAlpha: 0.16)
    static let ink = dynamic(light: 0x0E2A3B, dark: 0xE5F5FC)
    static let muted = dynamic(light: 0x3B6E8C, dark: 0x9DC3D9)
    static let faint = dynamic(light: 0x3B637A, dark: 0x80A5BB)
    static let navy = dynamic(light: 0x0B4466, dark: 0xB4E5FF)
    static let accent = Color(hex: 0x5BD46A)
    static let stop = Color(hex: 0x0B6FB0)
    static let coral = dynamic(light: 0xE8392E, dark: 0xFF786E)
    static let validationText = dynamic(light: 0xB4231B, dark: 0xFF928A)
    static let validationBorder = dynamic(light: 0xC92F28, dark: 0xFF786E)
    static let validationFill = dynamic(light: 0xFDE9E7, dark: 0x4B2527, lightAlpha: 0.88, darkAlpha: 0.92)
    static let recordingText = dynamic(light: 0xB3140B, dark: 0xFF9D94)
    static let amber = dynamic(light: 0x80500A, dark: 0xE8B963)
    static let green = Color(hex: 0x34B84A)
    static let roomModeTint = dynamic(light: 0xD9F1DC, dark: 0x28563B)
    static let macModeTint = dynamic(light: 0xD7ECF8, dark: 0x1F5578)
    static let savedText = dynamic(light: 0x1E7A1A, dark: 0x85E28D)
    static let onAccent = Color(hex: 0x062A0C)
    static let accentText = dynamic(light: 0x0B5A8A, dark: 0x89D5FF)
    static let waveform = Color(hex: 0x0E4A70)
    static let wavePlayed = Color(hex: 0x7FE3FF)
    static let waveIdle = Color(hex: 0x2E6F96)
    // Transcripts button gloss (Frutiger Aero): aqua at the top, sky blue at the base.
    static let aeroTop = Color(hex: 0x6FDDF0)
    static let aeroMid = Color(hex: 0x13AAC9)
    static let aeroBase = Color(hex: 0x1E6FCF)
    static let aeroEdge = Color(hex: 0x0B4C86)
    static let aeroGlow = Color(hex: 0x00B4F0)
    // Choose destination: warm amber that reads on the light and dark raised fills.
    static let warmText = dynamic(light: 0x8A4B00, dark: 0xFFC978)
    static let warmFill = dynamic(light: 0xFCE8C4, dark: 0x4E3714, lightAlpha: 0.92, darkAlpha: 0.92)

    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let darkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(darkMode ? dark : light, alpha: darkMode ? darkAlpha : lightAlpha)
        })
    }
    fileprivate static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight) }
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static let label = text(11, .medium)
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: Theme.rgb(hex)) }
}

// The real app uses the desktop through native vibrancy. Snapshots supply their own backdrop.
private final class NosyEffectView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isOpaque = false
        window?.backgroundColor = .clear
        window?.titlebarAppearsTransparent = true
    }
}
private struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NosyEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.window?.isOpaque = false
        view.window?.backgroundColor = .clear
        view.window?.titlebarAppearsTransparent = true
    }
}
struct WindowBackdrop: View {
    var body: some View {
        ZStack {
            if !Snapshot.isRunning { WindowMaterial().allowsHitTesting(false) }
            Theme.background
        }.ignoresSafeArea()
    }
}

// The custom titlebar already includes the native titlebar's safe area. Report
// that inset so MainView subtracts it once from the hosting view's fitting height.
struct MainWindowChrome: NSViewRepresentable {
    @Binding var titlebarInset: CGFloat
    final class Anchor: NSView {
        var reportInset: ((CGFloat) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            centerTrafficLights()
        }
        @objc private func windowResized(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in self?.centerTrafficLights() }
        }
        func centerTrafficLights() {
            guard let window else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
                let center = parent.convert(NSPoint(x: bounds.midX, y: bounds.maxY - 22), from: self)
                let y = center.y - button.frame.height / 2
                if abs(button.frame.minY - y) > 0.1 { button.setFrameOrigin(NSPoint(x: button.frame.minX, y: y)) }
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(windowResized), name: NSWindow.didResizeNotification, object: window)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.hasShadow = false
            let inset = window.contentView?.safeAreaInsets.top ?? 0
            DispatchQueue.main.async { [weak self] in
                self?.reportInset?(inset)
                self?.centerTrafficLights()
            }
        }
    }
    func makeNSView(context: Context) -> NSView {
        let view = Anchor()
        view.reportInset = { titlebarInset = $0 }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

enum Motion {
    static let press = Animation.spring(duration: 0.2, bounce: 0.08)
    static let hover = Animation.easeOut(duration: 0.15)
    // A subtle spring preserves the existing responsive feel.
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
    var horizontalPadding: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, style: self)
    }
    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let style: PillButtonStyle
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isFocused) private var focused
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(Theme.text(style.height > 36 ? 15 : 13, .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, style.horizontalPadding ?? (style.height > 36 ? 20 : 14))
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
                .overlay(Capsule().strokeBorder(focused ? Theme.accentText : .clear, lineWidth: 2).padding(-3).allowsHitTesting(false))
                .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
                .animation(Motion.press, value: configuration.isPressed)
        }
        private var background: Color {
            switch style.kind {
            case .primary: style.tint
            case .dark: Theme.stop
            case .quiet: hovering && enabled ? Theme.surface : Theme.raised
            }
        }
        private var foreground: Color {
            switch style.kind {
            case .primary: Theme.onAccent
            case .dark: .white
            case .quiet: Theme.navy
            }
        }
        private var shadowColor: Color {
            guard enabled, style.kind != .quiet else { return .clear }
            return (style.kind == .primary ? Color(hex: 0x288C32) : Theme.stop).opacity(hovering ? 0.28 : 0.16)
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
            content.brightness(hovering ? 0.04 : 0).shadow(color: color, radius: hovering ? 12 : 10, y: hovering ? 9 : 8)
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
        @Environment(\.isFocused) private var focused
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: size, height: size)
                .background(hovering && enabled ? Theme.surface : Theme.raised, in: Circle())
                .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
                .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Circle())
                .overlay(Circle().strokeBorder(focused ? Theme.accentText : .clear, lineWidth: 2).padding(-2).allowsHitTesting(false))
                .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

// Grouped rows stay flat, with a quiet hover tint and the same tactile press response.
struct InsetButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { InsetBody(configuration: configuration) }
    private struct InsetBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isFocused) private var focused
        @State private var hovering = false
        var body: some View {
            configuration.label
                .brightness(hovering && enabled ? 0.025 : 0)
                .opacity(configuration.isPressed && enabled ? 0.8 : 1)
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.97 : 1)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Theme.accentText : .clear, lineWidth: 2).padding(-2).allowsHitTesting(false))
                .contentShape(Rectangle())
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
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(Theme.text(12.5, .semibold))
                .foregroundStyle(enabled ? tint : Theme.muted)
                .underline(hovering && enabled)
                .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
                .scaleEffect(configuration.isPressed && enabled ? 0.97 : 1)
                .contentShape(Rectangle())
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? Theme.accentText : .clear, lineWidth: 2).padding(-3).allowsHitTesting(false))
                .onHover { hovering = $0 }
        }
    }
}

// Text fields use the same translucent inset surfaces as the grouped main rows.
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
    var filled = false
    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, size: size, active: active, destructive: destructive, filled: filled)
    }
    private struct IconBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let active: Bool
        let destructive: Bool
        let filled: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isFocused) private var focused
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(hovering && enabled && destructive ? Theme.coral : (active || (hovering && enabled) ? Theme.accentText : Theme.muted))
                .frame(width: size, height: size)
                .background(configuration.isPressed && enabled ? Theme.line :
                    (hovering && enabled ? (destructive ? Theme.coral.opacity(0.14) : Theme.surface) :
                        (filled ? Theme.raised : .clear)), in: Circle())
                .overlay(Circle().strokeBorder(filled ? Theme.line : .clear).allowsHitTesting(false))
                .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Circle())
                .overlay(Circle().strokeBorder(focused ? Theme.accentText : .clear, lineWidth: 2).padding(-2).allowsHitTesting(false))
                .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

extension View {
    func fieldChrome(focused: Bool = false) -> some View { modifier(FieldChrome(focused: focused)) }
    func card(_ fill: Color = Theme.surface, radius: CGFloat = 12) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.panelBorder, lineWidth: 1).allowsHitTesting(false))
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

private let tipSpace = "nosyTips"

// A tip reports where its control sits. One layer at the window root draws the bubble,
// so no ScrollView or clip around a control can cut the bubble off.
private struct TipAnchor: Equatable {
    var text: String
    var edge: VerticalEdge
    var frame: CGRect
}

private struct TipAnchorKey: PreferenceKey {
    static let defaultValue: [TipAnchor] = []
    static func reduce(value: inout [TipAnchor], nextValue: () -> [TipAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

private struct TipPreviewEnvironmentKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var previewTipText: String? {
        get { self[TipPreviewEnvironmentKey.self] }
        set { self[TipPreviewEnvironmentKey.self] = newValue }
    }
}

// Pure geometry, so tests can check every anchor position against the window bounds.
enum TipPlacement {
    struct Layout: Equatable {
        var size: CGSize
        var center: CGPoint
    }
    static let margin: CGFloat = 12
    static let gap: CGFloat = 6
    static let minWidth: CGFloat = 76
    static let maxWidth: CGFloat = 232
    static let horizontalPadding: CGFloat = 7
    static let verticalPadding: CGFloat = 4
    static let maxLines: CGFloat = 2
    static var font: NSFont { NSFont.systemFont(ofSize: 10, weight: .medium) }

    static var lineHeight: CGFloat { ceil(("Ag" as NSString).size(withAttributes: [.font: font]).height) }

    // The height the text needs when wrapped to the bubble width, before any line limit.
    static func wrappedHeight(_ text: String, width: CGFloat) -> CGFloat {
        (text as NSString).boundingRect(
            with: CGSize(width: width - 2 * horizontalPadding, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
    }

    static func layout(text: String, edge: VerticalEdge, anchor: CGRect, container: CGSize) -> Layout {
        let oneLineWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let available = max(minWidth, min(maxWidth, container.width - 2 * margin))
        let width = min(max(minWidth, oneLineWidth + 2 * horizontalPadding), available)
        // Error details and file paths can need more than two lines. Fit the whole tip
        // whenever the window has room, rather than cutting off the only visible explanation.
        let textHeight = min(ceil(wrappedHeight(text, width: width)), max(lineHeight, container.height - 2 * margin - 2 * verticalPadding - 2))
        let height = max(24, textHeight + 2 * verticalPadding + 2)
        let halfWidth = width / 2
        let halfHeight = height / 2
        let centerX = clamp(anchor.midX, margin + halfWidth, container.width - margin - halfWidth)
        var centerY = edge == .top ? anchor.minY - gap - halfHeight : anchor.maxY + gap + halfHeight
        // Flip to the other side of the control when the bubble would leave the window.
        if edge == .top, centerY - halfHeight < margin { centerY = anchor.maxY + gap + halfHeight }
        if edge == .bottom, centerY + halfHeight > container.height - margin { centerY = anchor.minY - gap - halfHeight }
        centerY = clamp(centerY, margin + halfHeight, container.height - margin - halfHeight)
        return Layout(size: CGSize(width: width, height: height), center: CGPoint(x: centerX, y: centerY))
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}

private struct TipModifier: ViewModifier {
    let text: String
    let edge: VerticalEdge
    @State private var visible = false
    @State private var hoverTask: Task<Void, Never>?
    @Environment(\.previewTipText) private var previewTipText

    func body(content: Content) -> some View {
        content
            .onHover(perform: setHovering)
            .background {
                // The frame is only read while the tip shows, so tips outside a layer cost nothing.
                GeometryReader { proxy in
                    Color.clear.preference(key: TipAnchorKey.self,
                                           value: visible || previewTipText == text
                                               ? [TipAnchor(text: text, edge: edge, frame: proxy.frame(in: .named(tipSpace)))]
                                               : [])
                }
                .allowsHitTesting(false)
            }
            .onDisappear {
                hoverTask?.cancel()
                visible = false
            }
    }

    private func setHovering(_ inside: Bool) {
        hoverTask?.cancel()
        guard inside else {
            withAnimation(Motion.hover) { visible = false }
            return
        }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.hover) { visible = true }
        }
    }
}

// The bubble itself, drawn over the whole window and clipped with it.
private struct TipLayer: View {
    let anchor: TipAnchor?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { container in
            if let anchor {
                let layout = TipPlacement.layout(text: anchor.text, edge: anchor.edge,
                                                 anchor: anchor.frame, container: container.size)
                Text(anchor.text)
                    .font(Theme.text(10, .medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, TipPlacement.horizontalPadding)
                    .padding(.vertical, TipPlacement.verticalPadding)
                    .frame(width: layout.size.width, height: layout.size.height)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.panelBorder, lineWidth: 1))
                    .shadow(color: Theme.ink.opacity(0.14), radius: 8, y: 3)
                    .position(layout.center)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    func tip(_ text: String, edge: VerticalEdge = .top) -> some View {
        modifier(TipModifier(text: text, edge: edge))
    }
    // Attach once per window, inside the window's clip shape, so bubbles never leave the window.
    func tipContainerBounds() -> some View {
        coordinateSpace(name: tipSpace)
            .overlayPreferenceValue(TipAnchorKey.self) { anchors in
                TipLayer(anchor: anchors.first)
            }
    }
}
