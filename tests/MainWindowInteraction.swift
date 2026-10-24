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
        let browseProbe = BrowseActionProbe()
        let host = NSHostingView(rootView: MainView(model: model, onBrowse: { browseProbe.invoked = true }))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        await settle(host, window)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = window.standardWindowButton(kind)!
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            expect(abs(center.y - (host.bounds.height - 22)) < 1, "Traffic lights center \(center.y), expected \(host.bounds.height - 22)")
        }

        func target(_ id: String) -> NSView {
            guard let view = targets(in: host).first(where: { $0.id == id && !$0.visibleRect.isEmpty && !$0.isHiddenOrHasHiddenAncestor }) else {
                fail("Missing visible interaction target: \(id), present: \(targets(in: host).map(\.id))")
            }
            return view
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
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
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
        func inspectMenuItem(_ prefix: String, target targetID: String) async {
            let probe = MenuSelectionProbe(title: prefix)
            NotificationCenter.default.addObserver(probe, selector: #selector(MenuSelectionProbe.menuBegan),
                                                   name: NSMenu.didBeginTrackingNotification, object: nil)
            let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
                MainActor.assumeIsolated { probe.captureMenuItems() }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .default)
            await click(targetID)
            timer.invalidate()
            NotificationCenter.default.removeObserver(probe)
            expect(probe.itemTitles.contains(where: { $0.hasPrefix(prefix) }), "The folder menu includes \(prefix)")
        }

        let initialValidationRequest = model.startValidationRequest
        expect(model.session.isEmpty, "The Ready session name starts empty")
        let titlebarActions = target("titlebar-tools")
        expect(titlebarActions.bounds.width < 40, "GitHub is the only action at the right of the title bar")
        expect(targets(in: host).contains(where: { $0.id == "titlebar-github" }), "GitHub stays reachable in the title bar")
        sendKey("r", code: 15, modifiers: .command, window: window)
        await settle(host, window)
        expect(model.startValidationRequest == initialValidationRequest + 1, "Command R reaches the empty session gate")
        expect(model.phase == .idle && !model.busy, "An empty session never starts recording")
        await panel(true, "Command R opens the Session field")
        expect(targets(in: host).contains(where: { $0.id == "session-required-message" && !$0.visibleRect.isEmpty }),
               "The empty session message appears under the field")
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
        expect(browseProbe.invoked, "Browse activates the Transcripts action")
        await waitForTarget("dropdown-panel", visible: false, "Browse closes the Session panel")
        await click("dropdown-saveTo")
        expect(targets(in: host).contains(where: { $0.id == "save-to-wheel" && !$0.visibleRect.isEmpty }), "Save to rolls into the folder wheel")
        expect(targets(in: host).contains(where: { $0.id == "save-to-picker" && !$0.visibleRect.isEmpty }), "Folder choices appear beside the wheel")
        await waitForTarget("dropdown-session", visible: false, "Session hides while Save to is expanded")
        await click("save-to-wheel")
        await waitForTarget("save-to-picker", visible: false, "The wheel closes on a second click")
        await click("dropdown-saveTo")
        await inspectMenuItem("Choose destination", target: "save-to-picker")
        await chooseMenuItem("CHEM281", target: "save-to-picker")
        expect(model.selectedLecture == "CHEM281", "Picking an existing folder updates Save to")
        await waitForTarget("save-to-wheel", visible: false, "Choosing a folder rolls the wheel back")
        await click("dropdown-saveTo")
        await chooseMenuItem("New folder…", target: "save-to-picker")
        expect(model.selectedLecture == "__new__", "New folder starts a folder name entry")
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
        expect(targets(in: host).contains(where: { $0.id == "save-to-wheel" && !$0.visibleRect.isEmpty }), "Save to wheel reopens")
        await click("mode-mic")
        await waitForTarget("save-to-wheel", visible: false, "Clicking outside dismisses the folder wheel")
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
        expect(targets(in: host).contains(where: { $0.id == "save-to-wheel" && !$0.visibleRect.isEmpty }), "Press feedback keeps the original edge hit area clickable")
        sendKey("\u{1b}", code: 53, window: window)
        await settle(host, window)
        await waitForTarget("save-to-wheel", visible: false, "Escape also dismisses the folder wheel")
        print("MAIN WINDOW INTERACTION PASS: native hit testing, folder wheel, native folder menu, new folder typing, session typing, subject menu/autosave, disclosure/editor, outside control action, empty-space dismissal, Home navigation, Escape, repeat toggles, edge press and titlebar centering")
    }

    static func settle(_ host: NSView, _ window: NSWindow) async {
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(60))
            if host.bounds.size != host.fittingSize { window.setContentSize(host.fittingSize) }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            NSApp.updateWindows()
        }
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

@MainActor
private final class BrowseActionProbe {
    var invoked = false
}

// Failures print and exit instead of trapping, so no crash reporter dialog appears.
func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
    if !condition() { fail(message()) }
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("UI TEST FAILED: \(message)\n".utf8))
    exit(1)
}

@MainActor
private final class MenuSelectionProbe: NSObject {
    var menu: NSMenu?
    var selected = false
    var itemTitles: [String] = []
    private let title: String
    private let deadline = Date().addingTimeInterval(3)
    init(title: String = "Chemistry") { self.title = title }
    @objc func menuBegan(_ notification: Notification) { menu = notification.object as? NSMenu }
    func captureMenuItems() {
        guard let menu else { return }
        itemTitles = menu.items.map(\.title)
        menu.cancelTrackingWithoutAnimation()
    }
    func selectItem() {
        expect(selected || Date() < deadline, "Native menu selection timed out for \(title)")
        guard !selected, let menu, let index = menu.items.firstIndex(where: { $0.title == title }) else { return }
        menu.performActionForItem(at: index)
        selected = true
        menu.cancelTrackingWithoutAnimation()
    }
}
