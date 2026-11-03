import AppKit
import SwiftUI
import QuartzCore

@MainActor
final class WorkspaceNavigation: ObservableObject {
    enum Mode: String { case home, library }
    enum Panel { case settings, setup }
    @Published private(set) var mode: Mode = .home
    @Published private(set) var homeRequest = 0
    @Published private(set) var settingsPane: SettingsView.Pane = .general
    @Published private(set) var settingsFocusRequest: SettingsFocusRequest?
    @Published private(set) var panel: Panel?
    private var settingsFocusID = 0

    func showLibrary() { panel = nil; mode = .library }
    func showHome() { panel = nil; mode = .home }
    func requestHome() { homeRequest += 1 }
    func showSettings(pane: SettingsView.Pane = .general, focus: SettingsFocusTarget? = nil) {
        settingsPane = pane
        if let focus {
            settingsFocusID += 1
            settingsFocusRequest = SettingsFocusRequest(id: settingsFocusID, target: focus)
        } else {
            settingsFocusRequest = nil
        }
        panel = .settings
    }
    func settingsFocusHandled(_ id: Int) {
        if settingsFocusRequest?.id == id { settingsFocusRequest = nil }
    }
    func showSetup() { panel = .setup }
    func dismissPanel() { panel = nil }
}

// One shell owns the title bar, presentation and native frame. Both content trees
// stay mounted, retaining reader selection, drafts and Home's expanded controls.
struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var navigation: WorkspaceNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var homeHeight: CGFloat = 256
    var previewSize: CGSize?
    var previewSettingsPane: SettingsView.Pane = .general
    var previewLibrary: LibraryView?

    init(model: AppModel, previewSize: CGSize? = nil, previewSettingsPane: SettingsView.Pane = .general,
         previewLibrary: LibraryView? = nil) {
        self.model = model
        _navigation = ObservedObject(wrappedValue: model.workspace)
        self.previewSize = previewSize
        self.previewSettingsPane = previewSettingsPane
        self.previewLibrary = previewLibrary
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTitlebar(model: model, managesWindowChrome: true)
            Group {
                if model.recording {
                    RecordingModeBanner(model: model)
                    .padding(.horizontal, 20).padding(.vertical, 6)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(Motion.state(reduceMotion), value: model.recording)
            // Home keeps its natural height for the window; a screen too short for it scrolls instead of clipping.
            ScrollView {
                MainView(model: model, embedded: true,
                         telemetryVisible: navigation.mode == .home && navigation.panel == nil)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: HomeHeightKey.self, value: geometry.size.height)
                    })
                    .opacity(navigation.mode == .home ? 1 : 0)
                    .allowsHitTesting(navigation.mode == .home && navigation.panel == nil)
                    .accessibilityHidden(navigation.mode != .home || navigation.panel != nil)
                    .disabled(navigation.mode != .home || navigation.panel != nil)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay {
                VStack(spacing: 0) {
                    (previewLibrary ?? LibraryView(model: model,
                        telemetryVisible: navigation.mode == .library && navigation.panel == nil))
                    if navigation.mode == .library && model.recording {
                        LibraryRecordingBar(model: model, telemetryVisible: navigation.panel == nil)
                    }
                }
                .opacity(navigation.mode == .library ? 1 : 0)
                .allowsHitTesting(navigation.mode == .library && navigation.panel == nil)
                .accessibilityHidden(navigation.mode != .library || navigation.panel != nil)
                .disabled(navigation.mode != .library || navigation.panel != nil)
            }
            .overlay {
                if let panel = navigation.panel {
                    panelOverlay(panel)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                        .zIndex(10)
                }
            }
            .clipped()
        }
        // The native frame controller consumes homeHeight. Never also publish it
        // as an animated ideal size: NSHostingView can resize during windowDidLayout.
        .frame(minWidth: 0, idealWidth: 400, maxWidth: .infinity,
               minHeight: 0, idealHeight: 300, maxHeight: .infinity)
        .frame(width: previewSize?.width, height: previewSize?.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackdrop())
        .background {
            if previewSize == nil {
                WorkspaceWindowFrame(mode: navigation.mode, panel: navigation.panel,
                                     homeSize: CGSize(width: 400, height: homeHeight + 44 + (model.recording ? 54 : 0)), reduceMotion: reduceMotion,
                                     canClose: { model.finishLibraryEditing?() ?? true })
            }
        }
        .background {
            // Also present when hosting the workspace without an App scene (native tests).
            Button("Library") { model.showInLibrary(nil) }.keyboardShortcut("l", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            Button("Settings") { navigation.showSettings() }.keyboardShortcut(",", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            Button("Close panel") {
                if navigation.panel != nil { navigation.dismissPanel() }
                else if navigation.mode == .library { model.showHome() }
                else { NSApp.keyWindow?.performClose(nil) }
            }.keyboardShortcut("w", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            if navigation.panel != nil || navigation.mode == .library {
                Button("Return to Home") {
                    if navigation.panel != nil { navigation.dismissPanel() }
                    else { model.showHome() }
                }
                .keyboardShortcut(.cancelAction)
                .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onPreferenceChange(HomeHeightKey.self) { height in
            if height.isFinite, height > 0 {
                let measured = height.rounded(.up)
                DispatchQueue.main.async {
                    guard abs(measured - homeHeight) > 0.5 else { return }
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { homeHeight = measured }
                }
            }
        }
        .onExitCommand {
            if navigation.panel != nil { navigation.dismissPanel() }
            else if navigation.mode == .library { model.showHome() }
        }
        .onAppear {
            if model.needsOnboarding && !Snapshot.isRunning { navigation.showSetup() }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.18) : .spring(duration: 0.32, bounce: 0), value: navigation.panel)
        .tipContainerBounds()
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.panelBorder.opacity(0.78)).allowsHitTesting(false))
        // The custom 44-point title bar occupies the native title bar's area.
        // Do not feed AppKit safe-area measurements back into the root's padding.
        .ignoresSafeArea(.container, edges: .top)
    }

    private func panelOverlay(_ panel: WorkspaceNavigation.Panel) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
                    .onTapGesture { navigation.dismissPanel() }
                    .accessibilityLabel("Dismiss panel")
                VStack(spacing: 0) {
                    HStack {
                        Text(panel == .settings ? "Settings" : "Set up Nosy")
                            .font(Theme.display(15, .semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Button { navigation.dismissPanel() } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(IconButtonStyle(size: 28))
                        .accessibilityLabel("Close panel")
                        .tip("Close (Esc)")
                        .interactionTarget("panel-close")
                    }
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    Divider()
                    if panel == .settings {
                        SettingsView(model: model, pane: previewSize != nil ? previewSettingsPane : navigation.settingsPane,
                                     showsHeading: false,
                                     focusRequest: previewSize == nil ? navigation.settingsFocusRequest : nil,
                                     onFocusHandled: { navigation.settingsFocusHandled($0) })
                            .id(previewSize != nil ? previewSettingsPane : navigation.settingsPane)
                    } else {
                        ScrollView { OnboardingView(model: model) }.scrollIndicators(.never)
                    }
                }
                .frame(width: panel == .settings ? SettingsView.width : 520)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(WindowBackdrop())
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.panelBorder))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
                .padding(16)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
                .interactionTarget("workspace-panel")
            }
        }
    }
}

private struct HomeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct WorkspaceTitlebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var navigation: WorkspaceNavigation
    var onHome: (() -> Void)?
    private var managesWindowChrome: Bool
    init(model: AppModel, onHome: (() -> Void)? = nil, managesWindowChrome: Bool = false) {
        self.model = model
        _navigation = ObservedObject(wrappedValue: model.workspace)
        self.onHome = onHome
        self.managesWindowChrome = managesWindowChrome
    }
    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Color.clear.frame(width: 64).accessibilityHidden(true)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    StatusPill(model: model).fixedSize()
                    Button {
                        if navigation.mode == .library { model.showHome() }
                        else if let onHome { onHome() }
                        else { navigation.requestHome() }
                    } label: {
                        Image(systemName: "house").font(.system(size: 13, weight: .medium))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(TitlebarIconButtonStyle(ring: true))
                    .tip("Home", edge: .bottom)
                    .accessibilityLabel("Home")
                    .interactionTarget("titlebar-home")
                    .disabled(navigation.panel != nil)
                    Button { NSWorkspace.shared.open(URL(string: "https://github.com/bardya07/nosy")!) } label: {
                        Image(nsImage: Bundle.main.image(forResource: "GitHubMark") ?? NSImage())
                            .renderingMode(.template).resizable().interpolation(.high).scaledToFit()
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(TitlebarIconButtonStyle())
                    .tip("Open GitHub", edge: .bottom)
                    .accessibilityLabel("Open Nosy on GitHub")
                    .interactionTarget("titlebar-github")
                    Button { navigation.showSettings() } label: {
                        Image(systemName: "gearshape").font(.system(size: 13, weight: .medium))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(TitlebarIconButtonStyle())
                    .tip("Settings (⌘,)", edge: .bottom)
                    .accessibilityLabel("Settings")
                    .interactionTarget("titlebar-settings")
                }
                .interactionTarget("titlebar-tools")
            }
        }
        .padding(.horizontal, 12).frame(height: 44)
        .background(WindowBackdrop())
        .background {
            if managesWindowChrome { MainWindowChrome().allowsHitTesting(false) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .interactionTarget("workspace-titlebar")
    }
}

// The bar's elapsed time. Only this text follows the recorder's length samples.
private struct RecordingBarClock: View {
    @ObservedObject var telemetry: RecordingTelemetry
    var body: some View {
        Text(Core.timer(telemetry.duration)).font(Theme.text(13, .semibold)).monospacedDigit()
    }
}

private struct LibraryRecordingBar: View {
    @ObservedObject var model: AppModel
    let telemetryVisible: Bool
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(model.paused ? Theme.amber : Theme.coral).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.paused ? "Recording paused" : "Recording")
                    .font(Theme.text(12, .semibold)).foregroundStyle(Theme.ink)
                Text(model.current?.lecture ?? model.lectureName)
                    .font(Theme.text(10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            if telemetryVisible {
                RecordingBarClock(telemetry: model.telemetry)
                LiveLevelReadout(telemetry: model.telemetry)
            } else {
                Text(Core.timer(model.duration)).font(Theme.text(13, .semibold)).monospacedDigit()
                FrozenLevelReadout(level: model.level)
            }
            Spacer(minLength: 0)
            Button { model.addMarker() } label: { Image(systemName: "bookmark") }
                .accessibilityLabel("Add marker")
                .tip("Add marker (⌘M)")
                .keyboardShortcut("m", modifiers: .command)
                .buttonStyle(IconButtonStyle(size: 32))
                .interactionTarget("library-marker")
            Button(model.paused ? "Resume" : "Pause") { model.togglePause() }
                .buttonStyle(PillButtonStyle(kind: .quiet, height: 32, fullWidth: false))
                .keyboardShortcut("p", modifiers: .command)
                .interactionTarget("library-pause")
            Button("Stop & transcribe") { model.stop() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(PillButtonStyle(kind: .dark, height: 32, fullWidth: false))
                .interactionTarget("library-stop")
        }
        .disabled(model.transitioning)
        .padding(.horizontal, 18).frame(height: 62)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .interactionTarget("library-recording-bar")
    }
}

// Pure frame policy is exercised against unplugged displays and smaller screens.
enum WorkspaceGeometry {
    static func clamped(_ frame: NSRect, to visible: NSRect) -> NSRect {
        let size = NSSize(width: min(max(1, frame.width), visible.width), height: min(max(1, frame.height), visible.height))
        return NSRect(x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - size.height), width: size.width, height: size.height)
    }
    static func screen(for frame: NSRect, screens: [NSRect]) -> NSRect? {
        screens.max { a, b in
            let aa = a.intersection(frame), bb = b.intersection(frame)
            return (aa.isNull ? 0 : aa.width * aa.height) < (bb.isNull ? 0 : bb.width * bb.height)
        }
    }
}

// Type erase only the public sizing API of the containing NSHostingView. The
// window belongs to SwiftUI's scene, but its frame belongs to the controller below.
@MainActor
private protocol WorkspaceHostingSizing: AnyObject {
    var sizingOptions: NSHostingSizingOptions { get set }
}
extension NSHostingView: WorkspaceHostingSizing {}

// SwiftUI measures Home; AppKit alone animates and clamps the native window.
// The saved base frame never includes a panel's temporary expansion.
struct WorkspaceWindowFrame: NSViewRepresentable {
    var mode: WorkspaceNavigation.Mode
    var panel: WorkspaceNavigation.Panel?
    var homeSize: CGSize
    var reduceMotion: Bool
    var canClose: () -> Bool
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.request = self
        view.schedule()
    }
    final class Anchor: NSView, NSWindowDelegate {
        var request: WorkspaceWindowFrame?
        private weak var attachedWindow: NSWindow?
        private var previous: WorkspaceWindowFrame?
        private var frames: [WorkspaceNavigation.Mode: NSRect] = [:]
        private var baseBeforePanel: NSRect?
        private var updating = false
        private var scheduled = false
        private var needsScreenClamp = true
        private var attachmentGeneration = 0
        // Base frames are kept in memory while they change and written once they settle.
        private var unsavedMode: WorkspaceNavigation.Mode?
        private var savedFrames: [WorkspaceNavigation.Mode: String] = [:]
        private var saveTask: Task<Void, Never>?
        // AppKit calls Objective C delegate discovery on the main thread, but
        // NSObject declares these forwarding methods nonisolated.
        nonisolated(unsafe) private weak var originalDelegate: (any NSWindowDelegate)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard attachedWindow !== window else { return }
            flushFrame()
            if let attachedWindow, attachedWindow.delegate === self { attachedWindow.delegate = originalDelegate }
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            attachedWindow = window
            attachmentGeneration &+= 1
            previous = nil
            baseBeforePanel = nil
            updating = false
            needsScreenClamp = true
            guard let window else { return }
            originalDelegate = window.delegate
            window.delegate = self
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(frameChanged), name: name, object: window)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSWindow.didChangeScreenNotification, object: window)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensChanged), name: NSWorkspace.didWakeNotification, object: nil)
            schedule()
        }
        override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return originalDelegate?.responds(to: selector) ?? false
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            let delegate = originalDelegate
            return delegate?.responds(to: selector) == true ? delegate : super.forwardingTarget(for: selector)
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard request?.canClose() ?? true else { return false }
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }
        func windowWillClose(_ notification: Notification) {
            flushFrame()
            originalDelegate?.windowWillClose?(notification)
        }
        func schedule() {
            // Animation completion reschedules anything received while updating.
            guard !scheduled, !updating else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.scheduled = false }
                self.apply()
            }
        }
        private var defaults: UserDefaults? { Snapshot.isRunning ? nil : .standard }
        private func saved(_ mode: WorkspaceNavigation.Mode) -> NSRect? {
            if let frame = frames[mode] { return frame }
            guard let value = defaults?.string(forKey: "workspace.frame.\(mode.rawValue)") else { return nil }
            let frame = NSRectFromString(value)
            return frame.width > 0 && frame.height > 0 ? frame : nil
        }
        // Updates the in-memory base frame. The preference is written after a quiet period, or at once when asked.
        private func remember(_ frame: NSRect, mode: WorkspaceNavigation.Mode, immediately: Bool = false) {
            frames[mode] = frame
            unsavedMode = mode
            saveTask?.cancel()
            guard !immediately else { flushFrame(); return }
            saveTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.flushFrame()
            }
        }
        // Writes the pending base frame, skipping the write when UserDefaults already holds that value.
        private func flushFrame() {
            saveTask?.cancel()
            saveTask = nil
            guard let mode = unsavedMode, let frame = frames[mode] else { return }
            unsavedMode = nil
            let key = "workspace.frame.\(mode.rawValue)"
            let value = NSStringFromRect(frame)
            guard (savedFrames[mode] ?? defaults?.string(forKey: key)) != value else { return }
            savedFrames[mode] = value
            defaults?.set(value, forKey: key)
        }
        @objc private func frameChanged(_ note: Notification) {
            guard !updating, let window, let request, previous != nil else { return }
            if request.panel == nil, previous?.mode == request.mode, previous?.panel == nil {
                remember(window.frame, mode: request.mode, immediately: note.name == NSWindow.didEndLiveResizeNotification)
            }
        }
        @objc private func screensChanged(_ note: Notification) {
            // These notifications can arrive inside AppKit's display/layout pass.
            needsScreenClamp = true
            schedule()
        }
        private func apply() {
            guard !updating, let window, let request else { return }
            let modeChanged = previous?.mode != request.mode
            let panelChanged = previous?.panel != request.panel
            let sizeChanged = previous?.homeSize != request.homeSize && request.mode == .home && request.panel == nil
            guard modeChanged || panelChanged || sizeChanged || needsScreenClamp else { return }
            needsScreenClamp = false
            if let previous, previous.panel == nil { remember(window.frame, mode: previous.mode, immediately: true) }
            var frame = window.frame
            if modeChanged {
                frame = saved(request.mode) ?? window.frame
                if request.mode == .library, saved(.library) == nil {
                    let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: CGSize(width: 1000, height: 680))).size
                    frame = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
                }
            } else if panelChanged, request.panel == nil, let baseBeforePanel {
                frame = baseBeforePanel
            }
            if request.mode == .home && request.panel == nil {
                let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: request.homeSize)).size
                frame = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
            }
            if request.panel != nil {
                if previous?.panel == nil || modeChanged { baseBeforePanel = frame }
                let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: CGSize(width: 680, height: 680))).size
                let enlarged = NSSize(width: max(frame.width, size.width), height: max(frame.height, size.height))
                frame = NSRect(x: frame.midX - enlarged.width / 2, y: frame.maxY - enlarged.height, width: enlarged.width, height: enlarged.height)
            }
            let visible = WorkspaceGeometry.screen(for: frame, screens: NSScreen.screens.map(\.visibleFrame)) ?? NSScreen.main?.visibleFrame ?? frame
            frame = WorkspaceGeometry.clamped(frame, to: visible)
            updating = true
            // Disable hosting-size propagation before touching native bounds. In
            // particular, an animated SwiftUI ideal size must never setFrame from
            // NSHostingView.windowDidLayout and invalidate the safe area again.
            var ancestor = superview
            while let view = ancestor {
                if let host = view as? any WorkspaceHostingSizing, !host.sizingOptions.isEmpty {
                    host.sizingOptions = []
                }
                ancestor = view.superview
            }
            let frameChanged = abs(frame.minX - window.frame.minX) > 0.5 || abs(frame.minY - window.frame.minY) > 0.5
                || abs(frame.width - window.frame.width) > 0.5 || abs(frame.height - window.frame.height) > 0.5
            if frameChanged {
                if window.contentMinSize != .zero { window.contentMinSize = .zero }
                let unlimited = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                if window.contentMaxSize != unlimited { window.contentMaxSize = unlimited }
            }
            // A mode switch changes the reader's width and lays out its native text
            // views. Go straight to the saved frame instead of repeating that work
            // at every intermediate width of a window animation.
            let animated = frameChanged && !modeChanged && (panelChanged || sizeChanged) && previous != nil && !request.reduceMotion && window.isVisible
            let generation = attachmentGeneration
            previous = request
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated ? 0.28 : 0
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                if frameChanged {
                    if animated { window.animator().setFrame(frame, display: true) }
                    else { window.setFrame(frame, display: true) }
                }
            } completionHandler: { [weak self, weak window] in
                // Even a zero-duration completion must leave the layout stack
                // before changing size limits (which can resize a window too).
                DispatchQueue.main.async {
                    guard let self, let window, self.attachedWindow === window,
                          self.attachmentGeneration == generation, let completed = self.previous else { return }
                    defer { self.updating = false; self.schedule() }
                    // Finish the frame that actually animated. A newer request must not
                    // save a temporary panel frame or discard the base we need to restore.
                    guard let latest = self.request, latest.mode == completed.mode, latest.panel == completed.panel,
                          completed.mode != .home || completed.panel != nil || latest.homeSize == completed.homeSize else { return }
                    let screen = window.screen?.visibleFrame ?? visible
                    let minSize = completed.panel != nil ? CGSize(width: 680, height: 520)
                        : completed.mode == .home ? completed.homeSize : CGSize(width: 720, height: 566)
                    let minimum = CGSize(width: min(minSize.width, screen.width), height: min(minSize.height, screen.height))
                    let maximum = completed.mode == .home && completed.panel == nil ? minimum
                        : NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                    if window.contentMaxSize != maximum { window.contentMaxSize = maximum }
                    if window.contentMinSize != minimum { window.contentMinSize = minimum }
                    if completed.panel == nil { self.remember(window.frame, mode: completed.mode, immediately: true); self.baseBeforePanel = nil }
                }
            }
        }
    }
}
