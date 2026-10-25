import AppKit
import SwiftUI

// Real hosted SwiftUI controls, AppKit hit testing, and mouse/key delivery.
// Fixtures never launch a recorder, play audio, or access owner files.
@MainActor
enum MainWindowInteraction {
    static func run(model: AppModel) async throws {
        // Posted clicks need an unlocked, active GUI session; a locked screen makes
        // every focus and hit check fail for reasons unrelated to the app.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true {
            print("MAIN WINDOW INTERACTION SKIPPED: screen is locked; rerun tests/run_unit.sh while logged in")
            return
        }
        let host = NSHostingView(rootView: WorkspaceView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Nosy"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        await settle(host, window)
        guard let titlebar = targets(in: host).first(where: { $0.id == "workspace-titlebar" }) else {
            fail("Missing workspace title bar measurement")
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = window.standardWindowButton(kind)!
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let titlebarCenter = titlebar.convert(NSPoint(x: titlebar.bounds.midX, y: titlebar.bounds.midY), to: nil)
            expect(abs(center.y - titlebarCenter.y) < 1,
                   "Traffic lights center \(center.y), expected title bar center \(titlebarCenter.y)")
        }

        func target(_ id: String) -> NSView {
            guard let view = targets(in: host).first(where: { $0.id == id && !$0.visibleRect.isEmpty && !$0.isHiddenOrHasHiddenAncestor }) else {
                fail("Missing visible interaction target: \(id), present: \(targets(in: host).map(\.id))")
            }
            return view
        }
        func expectTrafficLightsCentered(_ state: String) {
            let bar = target("workspace-titlebar")
            let expected = bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil).y
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                let button = window.standardWindowButton(kind)!
                let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil).y
                expect(abs(center - expected) < 1, "Traffic lights stay centered in the title bar during \(state)")
            }
        }
        func click(_ id: String) async {
            // Posted events do not activate an app as a physical mouse click
            // would. Native menu cancellation can also relinquish the key window.
            if !NSApp.isActive || !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                await settle(host, window)
            }
            let view = target(id)
            // SwiftUI can animate a representable's layer independently of its NSView frame.
            // Accessibility reports the rendered control, so posted clicks use that rectangle.
            let point: NSPoint
            if let frame = accessibilityFrame(id, in: host) {
                point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            } else {
                point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            }
            expect(host.hitTest(host.convert(point, from: nil)) != nil, "No hit at \(id)")
            sendClick(point, window: window)
            await settle(host, window)
        }
        func hasVisibleTarget(_ id: String) -> Bool {
            targets(in: host).contains(where: { $0.id == id && !$0.visibleRect.isEmpty && !$0.isHiddenOrHasHiddenAncestor })
        }
        func waitForTarget(_ id: String, visible: Bool, _ message: String) async {
            for _ in 0..<12 {
                if hasVisibleTarget(id) == visible { return }
                await settle(host, window)
            }
            if hasVisibleTarget(id) != visible {
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/nosy-workspace-failure.png"))
                }
            }
            expect(hasVisibleTarget(id) == visible, message)
        }
        // Removal transitions keep a closing panel in the tree briefly; poll for the end state.
        func panel(_ open: Bool, _ message: String) async {
            func shown() -> Bool { targets(in: host).contains(where: { $0.id == "dropdown-panel" && !$0.visibleRect.isEmpty }) }
            for _ in 0..<20 where shown() != open { await settle(host, window) }
            expect(shown() == open, message)
        }
        func chooseMenuItem(_ title: String, target targetID: String) async {
            let probe = MenuSelectionProbe(title: title)
            NotificationCenter.default.addObserver(probe, selector: #selector(MenuSelectionProbe.menuBegan),
                                                   name: NSMenu.didBeginTrackingNotification, object: nil)
            let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
                MainActor.assumeIsolated { probe.selectItem() }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .default)
            await click(targetID)
            timer.invalidate()
            NotificationCenter.default.removeObserver(probe)
            expect(probe.selected, "The native menu selects \(title)")
        }
        let initialValidationRequest = model.startValidationRequest
        expect(model.session.isEmpty, "The Ready session name starts empty")
        let titlebarActions = target("titlebar-tools")
        expect(titlebarActions.bounds.width < 70, "GitHub and Settings are the only actions at the right of the title bar")
        expect(targets(in: host).contains(where: { $0.id == "titlebar-github" }), "GitHub stays reachable in the title bar")
        expect(targets(in: host).contains(where: { $0.id == "titlebar-settings" }), "Settings stays reachable in the title bar")
        sendKey("r", code: 15, modifiers: .command, window: window)
        await settle(host, window)
        expect(model.startValidationRequest == initialValidationRequest + 1, "Command R reaches the empty session gate")
        expect(model.phase == .idle && !model.busy, "An empty session never starts recording")
        await panel(true, "Command R opens the Session field")
        func messageShown() -> Bool { targets(in: host).contains(where: { $0.id == "session-required-message" && !$0.visibleRect.isEmpty }) }
        for _ in 0..<20 where !messageShown() { await settle(host, window) }
        expect(messageShown(),
               "The empty session message appears above the field")
        expect(window.firstResponder is NSTextView, "Command R focuses the Session field")
        expect((window.firstResponder as? NSTextView)?.string.isEmpty == true, "The Session field has no default date")
        await click("primary-action")
        expect(model.startValidationRequest == initialValidationRequest + 2, "Start recording also checks the empty session")
        expect(model.phase == .idle && !model.busy, "The Start button stays active but does not record")
        await click("session-today")
        expect(model.session == AppModel.today, "The calendar button fills today's date")
        expect(!targets(in: host).contains(where: { $0.id == "session-required-message" && !$0.visibleRect.isEmpty }),
               "The required message clears after entering a session name")
        await click("browse-transcripts")
        expect(model.workspace.mode == .library, "Browse activates Library in the same window")
        expect(window.frame.width >= 720, "Library expands the shared window")
        expectTrafficLightsCentered("Library resize")
        expect(NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }.map(\.windowNumber) == [window.windowNumber], "Navigation retains one native window")
        await click("library-home")
        expect(model.workspace.mode == .home && abs(window.frame.width - 400) < 1, "The Nosy arrow returns and shrinks Home")
        expectTrafficLightsCentered("Home resize")
        await waitForTarget("dropdown-panel", visible: false, "Browse closes the Session panel")
        let browse = target("browse-transcripts")
        expect(browse.bounds.width > 80 && browse.bounds.height < 50, "Library is a labeled pill in the window row")
        let primary = target("primary-action")
        let primaryFrame = primary.convert(primary.bounds, to: host)
        let browseFrame = browse.convert(browse.bounds, to: host)
        expect(primaryFrame.maxX <= browseFrame.minX && browseFrame.maxX <= host.bounds.width - 20 + 1,
               "Start recording and Library fit the window row")
        await click("dropdown-saveTo")
        expect(hasVisibleTarget("save-to-group"), "Save to rolls into the folder group")
        expect(hasVisibleTarget("save-to-pick") && hasVisibleTarget("save-to-destination"),
               "Pick folder and Choose destination share the group")
        await waitForTarget("dropdown-session", visible: false, "The Session pill hides while Save to is expanded")
        expect(hasVisibleTarget("wheel-session") && hasVisibleTarget("wheel-vocabulary"),
               "Session and Vocabulary stay as bubbles while the wheel is open")
        let vocabBubble = target("wheel-vocabulary")
        expect(vocabBubble.convert(vocabBubble.bounds, to: host).maxX <= host.bounds.width - 20 + 1,
               "The open wheel row fits inside the window margins")
        for _ in 0..<4 { await settle(host, window) }
        await click("wheel-session")
        await waitForTarget("save-to-group", visible: false, "The Session bubble rolls the wheel back")
        await panel(true, "The Session bubble opens the Session panel")
        await click("dropdown-saveTo")
        await click("wheel-vocabulary")
        await waitForTarget("save-to-group", visible: false, "The Vocabulary bubble rolls the wheel back")
        await panel(true, "The Vocabulary bubble opens the Vocabulary panel")
        await click("dropdown-saveTo")
        await waitForTarget("save-to-group", visible: true, "The wheel reopens after a bubble")
        for _ in 0..<8 { await settle(host, window) }
        await click("save-to-wheel")
        await waitForTarget("save-to-group", visible: false, "The wheel closes on a second click")
        await click("dropdown-saveTo")
        await click("save-to-pick")
        await waitForTarget("save-to-folders", visible: true, "Pick folder opens the folder list below the group")
        expect(hasVisibleTarget("new-folder") && hasVisibleTarget("folder-CHEM281"), "The folder list shows folders and New folder")
        await click("save-to-pick")
        await waitForTarget("save-to-folders", visible: false, "Pick folder again closes the list")
        expect(hasVisibleTarget("save-to-group"), "Closing the list keeps the wheel open")
        await click("save-to-pick")
        await click("folder-CHEM281")
        expect(model.selectedLecture == "CHEM281", "Picking an existing folder updates Save to")
        await waitForTarget("save-to-group", visible: false, "Choosing a folder rolls the wheel back")
        await click("dropdown-saveTo")
        await click("save-to-pick")
        // The list eases in with a spring; wait for it to settle before clicking inside it.
        await waitForTarget("save-to-folders", visible: true, "Pick folder reopens the list after a rollback")
        for _ in 0..<8 { await settle(host, window) }
        await click("new-folder")
        expect(model.selectedLecture == "__new__", "New folder starts a folder name entry, selected \(model.selectedLecture)")
        await click("folder-name")
        expect(window.firstResponder is NSTextView, "New folder receives text focus")
        (window.firstResponder as? NSTextView)?.insertText("Seminar", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle(host, window)
        expect(model.newLecture == "Seminar", "New folder accepts typing")
        await click("new-folder-done")
        expect(model.lectureName == "Seminar", "Done keeps the new folder selection")
        model.selectedLecture = "MBB322"
        await settle(host, window)
        await click("dropdown-session")
        await click("session-name")
        await panel(true, "Clicking the session field must not dismiss it")
        expect(window.firstResponder is NSTextView, "Session field receives focus")
        (window.firstResponder as? NSTextView)?.insertText(" Notes", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle(host, window)
        expect(model.session.hasSuffix(" Notes"), "Session typing reaches the binding")
        await click("dropdown-vocabulary")
        await panel(true, "Switching directly to Vocabulary opens it once")
        expect(targets(in: host).contains(where: { $0.id == "vocabulary-setting-caption" && !$0.visibleRect.isEmpty }),
               "Vocabulary shows the Setting caption")
        expect(targets(in: host).contains(where: { $0.id == "vocabulary-help" && !$0.visibleRect.isEmpty }),
               "Vocabulary shows its explanation button")
        expect(target("subject-menu").bounds.width > 250, "The subject picker fills the panel width")
        await chooseMenuItem("Chemistry", target: "subject-menu")
        await panel(true, "Selecting a subject leaves the editor open")
        try await Task.sleep(for: .milliseconds(450))
        let savedSubject = try SubjectSettings.load(folder: model.paths.lectureFolder("MBB322"))
        expect(savedSubject.subject == "chemistry", "Subject selection autosaves to the captured folder")
        await click("custom-terms-disclosure")
        await panel(true, "Custom terms disclosure stays open")
        await click("custom-terms-editor")
        // A posted click right after native menu tracking can land before AppKit
        // restores the key window; one retry keeps this check deterministic.
        if !(window.firstResponder is NSTextView) { await click("custom-terms-editor") }
        await panel(true, "Clicking the custom terms editor stays inside the panel")
        expect(window.firstResponder is NSTextView, "Custom terms editor receives focus")
        (window.firstResponder as? NSTextView)?.insertText(" ATP", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle(host, window)
        await panel(true, "Vocabulary autosave does not dismiss the editor")
        await click(RecordingSource.macAudioAvailable ? "mode-both" : "mode-mic")
        await panel(false, "An outside control gets its click and dismisses the panel")
        expect(model.recordingSource == (RecordingSource.macAudioAvailable ? .both : .mic), "Outside mode click reaches its action")
        await click("dropdown-saveTo")
        await click("save-to-pick")
        await waitForTarget("save-to-folders", visible: true, "Save to reopens with its folder list")
        await click("mode-mic")
        await waitForTarget("save-to-group", visible: false, "Clicking outside dismisses the folder wheel and its list")
        expect(!hasVisibleTarget("save-to-folders"), "Clicking outside also closes the folder list")
        await click("dropdown-session")
        sendKey("\u{1b}", code: 53, window: window)
        await settle(host, window)
        await panel(false, "Escape dismisses the focused session panel")
        for _ in 0..<3 {
            await click("dropdown-vocabulary")
            await panel(true, "Repeated open")
            await click("dropdown-vocabulary")
            await panel(false, "Repeated close has no double toggle")
        }
        model.phase = .done
        await settle(host, window)
        expect(targets(in: host).contains(where: { $0.id == "primary-action" && !$0.visibleRect.isEmpty }), "Saved screen has a Home action")
        await click("primary-action")
        expect(model.phase == .idle, "Home returns Saved to Ready")
        expect(targets(in: host).contains(where: { $0.id == "mode-mic" && !$0.visibleRect.isEmpty }), "Ready mode controls return with Home")
        model.phase = .failed
        await settle(host, window)
        await click("primary-action")
        expect(model.phase == .idle, "Failed screen has a path Home")
        let edge = target("dropdown-saveTo")
        let point = edge.convert(NSPoint(x: edge.bounds.maxX - 0.5, y: edge.bounds.midY), to: nil)
        postMouse(.leftMouseDown, at: point, window: window)
        try await Task.sleep(for: .milliseconds(200))
        postMouse(.leftMouseUp, at: point, window: window)
        await settle(host, window)
        expect(hasVisibleTarget("save-to-group"), "Press feedback keeps the original edge hit area clickable")
        await click("save-to-pick")
        await waitForTarget("save-to-folders", visible: true, "Pick folder opens its list before Escape")
        sendKey("\u{1b}", code: 53, window: window)
        await settle(host, window)
        await waitForTarget("save-to-group", visible: false, "Escape rolls the folder wheel back with its list")
        expect(!hasVisibleTarget("save-to-folders"), "Escape also closes the folder list")
        // The shared window restores each base frame after a panel, including at screen edges.
        sendKey("\u{1b}", code: 53, window: window)
        await settle(host, window)
        for _ in 0..<5 { await settle(host, window) }
        let homeFrame = window.frame
        await click("titlebar-settings")
        expect(model.workspace.panel == .settings, "The gear opens Settings inside Home")
        expectTrafficLightsCentered("Settings over Home")
        expect(hasVisibleTarget("workspace-panel") && hasVisibleTarget("settings-pane-connect"), "The panel includes its sidebar")
        expect(window.frame.width >= 656, "Home expands to fit Settings")
        await click("settings-pane-summaries")
        expect(hasVisibleTarget("settings-ai-features"), "Summaries exposes the AI features switch")
        await click("settings-pane-connect")
        await click("panel-close")
        for _ in 0..<4 { await settle(host, window) }
        expect(model.workspace.panel == nil && abs(window.frame.width - 400) < 1, "Closing Settings restores compact Home")
        expectTrafficLightsCentered("Settings close")
        expect(abs(window.frame.minX - homeFrame.minX) < 1 && abs(window.frame.maxY - homeFrame.maxY) < 1,
               "Home's position survives Settings expansion")
        sendKey(",", code: 43, modifiers: .command, window: window)
        await settle(host, window)
        expect(model.workspace.panel == .settings, "Command comma opens the in-window panel")
        sendKey("\u{1b}", code: 53, window: window)
        await settle(host, window)
        expect(model.workspace.panel == nil, "Escape closes Settings")
        sendKey("l", code: 37, modifiers: .command, window: window)
        await settle(host, window)
        expect(model.workspace.mode == .library, "Command L opens Library")
        expectTrafficLightsCentered("Command L resize")
        for _ in 0..<4 { await settle(host, window) }
        let libraryFrame = window.frame
        await click("titlebar-settings")
        await click("panel-close")
        for _ in 0..<4 { await settle(host, window) }
        expect(window.frame == libraryFrame && model.workspace.mode == .library, "Settings restores Library's frame and mode")
        let originalFinish = model.finishLibraryEditing
        model.finishLibraryEditing = { false }
        await click("library-home")
        expect(model.workspace.mode == .library, "Cancelling a dirty draft blocks Home navigation")
        window.performClose(nil)
        expect(window.isVisible, "Cancelling a dirty draft blocks the native close button")
        model.finishLibraryEditing = originalFinish
        // A preview phase never starts audio hardware. Browsing and presentation cannot stop it.
        model.phase = .recording
        await settle(host, window)
        expect(hasVisibleTarget("library-recording-bar") && hasVisibleTarget("library-pause") && hasVisibleTarget("library-stop")
               && hasVisibleTarget("library-marker"), "Recording controls stay reachable while browsing")
        await click("titlebar-settings")
        await click("panel-close")
        expect(model.recording, "Recording survives Settings over Library")
        await click("library-home")
        expect(model.recording && model.workspace.mode == .home, "Recording survives the return Home")
        model.phase = .idle
        await settle(host, window)
        // User movement is remembered independently for each mode.
        if let screen = window.screen?.visibleFrame {
            let moved = WorkspaceGeometry.clamped(window.frame.offsetBy(dx: 30, dy: -20), to: screen)
            window.setFrame(moved, display: true)
            await settle(host, window)
            model.workspace.showLibrary()
            for _ in 0..<4 { await settle(host, window) }
            expect(window.frame == libraryFrame, "Library retains its own position and size")
            model.showHome()
            for _ in 0..<4 { await settle(host, window) }
            expect(abs(window.frame.minX - moved.minX) < 1 && abs(window.frame.maxY - moved.maxY) < 1, "Home retains its own position")
            expect(screen.contains(window.frame), "The shared window is fully on screen")
        }
        print("MAIN WINDOW INTERACTION PASS: native clicks, keyboard navigation, Home controls, Settings sidebar over both modes, frame restoration, dirty guards and Library recording controls")

    }

    static func settle(_ host: NSView, _ window: NSWindow) async {
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            NSApp.updateWindows()
        }
    }
    static func accessibilityFrame(_ id: String, in element: any NSAccessibilityProtocol) -> NSRect? {
        if element.accessibilityIdentifier() == id {
            let frame = element.accessibilityFrame()
            if frame.width > 0 && frame.height > 0 { return frame }
        }
        for child in element.accessibilityChildren() ?? [] {
            if let child = child as? any NSAccessibilityProtocol, let frame = accessibilityFrame(id, in: child) { return frame }
        }
        return nil
    }
    static func targets(in view: NSView) -> [InteractionTarget.Anchor] {
        (view as? InteractionTarget.Anchor).map { [$0] } ?? view.subviews.flatMap { targets(in: $0) }
    }
    static func sendClick(_ point: NSPoint, window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            postMouse(type, at: point, window: window)
        }
    }
    static func postMouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) {
        NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!, atStart: false)
    }
    static func sendKey(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) {
        NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!, atStart: false)
    }
}

// Failures print and exit instead of trapping, so no crash reporter dialog appears.
func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
    if !condition() { fail(message()) }
}
func fail(_ message: String) -> Never {
    MainActor.assumeIsolated {
        if let view = NSApp.keyWindow?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/nosy-one-window-ui-failure.png"))
        }
    }
    MainActor.assumeIsolated { print("WINDOWS \(NSApp.windows.map { ($0.title, $0.frame, $0.isKeyWindow) })") }
    FileHandle.standardError.write(Data("UI TEST FAILED: \(message)\n".utf8))
    exit(1)
}

@MainActor
private final class MenuSelectionProbe: NSObject {
    var menu: NSMenu?
    var selected = false
    private let title: String
    private let deadline = Date().addingTimeInterval(3)
    init(title: String = "Chemistry") { self.title = title }
    @objc func menuBegan(_ notification: Notification) { menu = notification.object as? NSMenu }
    func selectItem() {
        expect(selected || Date() < deadline, "Native menu selection timed out for \(title)")
        guard !selected, let menu, let index = menu.items.firstIndex(where: { $0.title == title }) else { return }
        menu.performActionForItem(at: index)
        selected = true
        menu.cancelTrackingWithoutAnimation()
    }
}
