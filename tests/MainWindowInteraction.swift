import AppKit
import SwiftUI

// Real hosted SwiftUI controls, AppKit hit testing, and mouse/key delivery.
// Fixtures never launch a recorder, play audio, or access owner files.
@MainActor
enum MainWindowInteraction {
    static func run(model: AppModel) async throws {
        let host = NSHostingView(rootView: MainView(model: model))
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
            precondition(abs(center.y - (host.bounds.height - 22)) < 1, "Traffic lights center \(center.y), expected \(host.bounds.height - 22)")
        }

        func target(_ id: String) -> NSView {
            guard let view = targets(in: host).first(where: { $0.id == id && !$0.visibleRect.isEmpty && !$0.isHiddenOrHasHiddenAncestor }) else {
                fatalError("Missing visible interaction target: \(id), present: \(targets(in: host).map(\.id))")
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
            precondition(host.hitTest(host.convert(point, from: nil)) != nil, "No hit at \(id)")
            sendClick(point, window: window)
            await settle(host, window)
        }
        func panel(_ open: Bool, _ message: String) {
            precondition(targets(in: host).contains(where: { $0.id == "dropdown-panel" && !$0.visibleRect.isEmpty }) == open, message)
        }
        await click("dropdown-saveTo")
        panel(true, "Save to opens on first click")
        await click("folder-MBB322")
        panel(true, "Choosing a folder keeps the panel open")
        await click("new-folder")
        panel(true, "New folder remains open")
        await click("folder-name")
        precondition(window.firstResponder is NSTextView, "New folder receives text focus")
        (window.firstResponder as? NSTextView)?.insertText("Seminar", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle(host, window)
        precondition(model.newLecture == "Seminar", "New folder accepts typing")
        await click("dropdown-saveTo")
        panel(false, "Same toggle closes without reopening")
        model.selectedLecture = "MBB322"
        await settle(host, window)
        await click("dropdown-session")
        await click("session-name")
        panel(true, "Clicking the session field must not dismiss it")
        precondition(window.firstResponder is NSTextView, "Session field receives focus")
        (window.firstResponder as? NSTextView)?.insertText(" Notes", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle(host, window)
        precondition(model.session.hasSuffix(" Notes"), "Session typing reaches the binding")
        await click("dropdown-vocabulary")
        panel(true, "Switching directly to Vocabulary opens it once")
        let menuSelection = MenuSelectionProbe()
        NotificationCenter.default.addObserver(menuSelection, selector: #selector(MenuSelectionProbe.menuBegan), name: NSMenu.didBeginTrackingNotification, object: nil)
        defer { NotificationCenter.default.removeObserver(menuSelection) }
        let selectionTimer = Timer(timeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated { menuSelection.selectChemistry() }
        }
        RunLoop.main.add(selectionTimer, forMode: .eventTracking)
        RunLoop.main.add(selectionTimer, forMode: .default)
        await click("subject-menu")
        selectionTimer.invalidate()
        precondition(menuSelection.selected, "The native subject menu opens and accepts a selection")
        panel(true, "Selecting a subject leaves the editor open")
        try await Task.sleep(for: .milliseconds(450))
        let savedSubject = try SubjectSettings.load(folder: model.paths.lectureFolder("MBB322"))
        precondition(savedSubject.subject == "chemistry", "Subject selection autosaves to the captured folder")
        await click("custom-terms-disclosure")
        panel(true, "Custom terms disclosure stays open")
        await click("custom-terms-editor")
        panel(true, "Clicking the custom terms editor stays inside the panel")
        precondition(window.firstResponder is NSTextView, "Custom terms editor receives focus")
        (window.firstResponder as? NSTextView)?.insertText(" ATP", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle(host, window)
        panel(true, "Vocabulary autosave does not dismiss the editor")
        await click(RecordingSource.macAudioAvailable ? "mode-both" : "mode-mic")
        panel(false, "An outside control gets its click and dismisses the panel")
        precondition(model.recordingSource == (RecordingSource.macAudioAvailable ? .both : .mic), "Outside mode click reaches its action")
        await click("dropdown-session")
        sendKey("\u{1b}", code: 53, window: window)
        await settle(host, window)
        panel(false, "Escape dismisses the focused session panel")
        for _ in 0..<3 {
            await click("dropdown-vocabulary")
            panel(true, "Repeated open")
            await click("dropdown-vocabulary")
            panel(false, "Repeated close has no double toggle")
        }
        let edge = target("dropdown-saveTo")
        let point = edge.convert(NSPoint(x: edge.bounds.maxX - 0.5, y: edge.bounds.midY), to: nil)
        postMouse(.leftMouseDown, at: point, window: window)
        try await Task.sleep(for: .milliseconds(200))
        postMouse(.leftMouseUp, at: point, window: window)
        await settle(host, window)
        panel(true, "Press feedback keeps the original edge hit area clickable")
        sendKey("\u{1b}", code: 53, window: window)
        await settle(host, window)
        panel(false, "Escape also dismisses the folder panel")
        print("MAIN WINDOW INTERACTION PASS: native hit testing, folder rows, new folder typing, session typing, subject menu/autosave, disclosure/editor, outside control action, Escape, repeat toggles, edge press and titlebar centering")
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
    static func sendKey(_ characters: String, code: UInt16, window: NSWindow) {
        NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!, atStart: false)
    }
}

@MainActor
private final class MenuSelectionProbe: NSObject {
    var menu: NSMenu?
    var selected = false
    private let deadline = Date().addingTimeInterval(3)
    @objc func menuBegan(_ notification: Notification) { menu = notification.object as? NSMenu }
    func selectChemistry() {
        precondition(selected || Date() < deadline, "Native subject menu selection timed out")
        guard !selected, let menu, let index = menu.items.firstIndex(where: { $0.title == "Chemistry" }) else { return }
        menu.performActionForItem(at: index)
        selected = true
        menu.cancelTrackingWithoutAnimation()
    }
}
