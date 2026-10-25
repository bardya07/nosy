import AppKit
import Foundation

// Transcripts folder delete (key path, focus and the "Don't ask again" suppression), the live level readout,
// the recording reminder interval, and the Claude Desktop connection copy. Uses temporary folders and
// throwaway defaults suites only, so nothing reaches the owner's real Trash, settings or Claude Desktop config.
@main
@MainActor
enum TranscriptsSettingsTests {
    static func main() {
        do {
            try run()
            print("TRANSCRIPTS SETTINGS TESTS PASS: folder Delete key and suppression, level estimate, reminder interval, connection copy")
        } catch {
            FileHandle.standardError.write(Data("TRANSCRIPTS SETTINGS TEST FAILED: \(error)\n".utf8))
            exit(1)
        }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("TRANSCRIPTS SETTINGS TEST FAILED: \(message)\n".utf8))
            exit(1)
        }
    }

    static func transcript(in folder: URL, name: String) throws {
        let text = """
        # \(folder.lastPathComponent)

        - Date: \(name)
        - Length: 1 min

        ## Transcript

        Some words.
        """
        try text.write(to: folder.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
    }

    static func run() throws {
        let minus = "\u{2212}"
        let suite = "nosy-round8-tests-\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite), "a throwaway defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }

        // Deleting a folder: the Trash confirmation can be turned off, and turned back on from Settings.
        check(LectureFolderTrash.asks(defaults), "folder deletes ask first until the owner says otherwise")
        defaults.set(false, forKey: LectureFolderTrash.askKey)
        check(!LectureFolderTrash.asks(defaults), "Don't ask again turns the confirmation off")
        check(LectureFolderTrash.confirm("MBB322", defaults: defaults), "a suppressed folder delete goes ahead without an alert")
        defaults.set(true, forKey: LectureFolderTrash.askKey)
        check(LectureFolderTrash.asks(defaults), "the Settings toggle turns the confirmation back on")
        let confirmation = LectureFolderTrash.makeConfirmation("MBB322")
        check(confirmation.alert.buttons.map(\.title) == ["Move to Trash", "Cancel"], "the folder alert offers Move to Trash and Cancel")
        check(confirmation.dontAsk.title == "Don't ask again" && confirmation.dontAsk.state == .off,
              "the folder alert offers an unchecked Don't ask again box")
        check(confirmation.alert.accessoryView === confirmation.dontAsk, "the box sits in the alert")

        // The Delete key path: a focused folder, cleared when a transcript is chosen, kept through reloads.
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("Nosy-round8-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(environment: ["NOSY_SUPPORT_DIR": root.appendingPathComponent("support").path,
                                           "NOSY_TRANSCRIPTS_DIR": root.appendingPathComponent("transcripts").path])
        try paths.prepareSupport()
        let mbb = paths.lectureFolder("MBB322")
        let chem = paths.lectureFolder("CHEM281")
        try FileManager.default.createDirectory(at: mbb, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chem, withIntermediateDirectories: true)
        try transcript(in: mbb, name: "2026-10-23")
        try transcript(in: chem, name: "2026-10-21")
        let chemURL = chem.appendingPathComponent("2026-10-21.md")

        let library = TranscriptLibrary()
        library.reload(paths: paths)
        check(library.focusedFolder == nil, "no folder has keyboard focus when the library opens")
        library.focusFolder("MBB322")
        check(library.focusedFolder == "MBB322", "a folder row takes keyboard focus")
        check(library.select(chemURL), "choosing a transcript succeeds")
        check(library.focusedFolder == nil, "choosing a transcript hands the keys back to the transcript")
        library.focusFolder("MBB322")
        library.reload(paths: paths)
        check(library.focusedFolder == "MBB322", "a reload keeps the focused folder while it still has transcripts")
        try FileManager.default.removeItem(at: mbb)
        library.reload(paths: paths)
        check(library.focusedFolder == nil, "a folder that left the library loses its focus")

        // The live level: an everyday estimate with a band, or the technical dBFS value.
        check(InputLevel.estimate(-38) == 56 && InputLevel.estimate(-32) == 62, "the estimate adds 94 dB to the dBFS level")
        check(InputLevel.estimate(-160) == 20 && InputLevel.estimate(-100) == 20 && InputLevel.estimate(.nan) == 20,
              "silence and missing readings sit at the bottom of the range")
        check(InputLevel.estimate(30) == 110, "the estimate tops out at 110 dB")
        check(InputLevel.estimateText(-32) == "\u{2248} 62 dB", "the everyday reading shows about 62 dB")
        check(InputLevel.technical(-38) == "\(minus)38 dBFS", "the technical reading is dB below full scale")
        check(InputLevel.technical(-23.6) == "\(minus)24 dBFS", "technical readings round to whole decibels")
        check(InputLevel.technical(0.4) == "0 dBFS", "full scale never reads positive")
        check(InputLevel.technical(-160) == "\(minus)\u{221E} dBFS", "silence reads as minus infinity")
        check(InputLevel.primary(-38, display: .estimate) == "\u{2248} 56 dB", "the estimate is the primary reading by default")
        check(InputLevel.primary(-38, display: .technical) == "\(minus)38 dBFS", "the technical reading can be the primary reading")
        check(InputLevel.band(-45) == .quiet && InputLevel.band(-44) == .good && InputLevel.band(-20) == .good
              && InputLevel.band(-19) == .loud, "Quiet below 50 dB, Good up to 74 dB, Loud from 75 dB")
        check(InputLevel.Band.quiet.label == "Quiet" && InputLevel.Band.good.label == "Good" && InputLevel.Band.loud.label == "Loud",
              "the bands are labelled Quiet, Good and Loud")
        check(LevelDisplay.stored(nil) == .estimate && LevelDisplay.stored("junk") == .estimate
              && LevelDisplay.stored("technical") == .technical, "the readout starts on the estimate")
        check(LevelDisplay.estimate.toggled == .technical && LevelDisplay.technical.toggled == .estimate, "a tap switches the reading")
        defaults.set(LevelDisplay.technical.rawValue, forKey: LevelDisplay.storageKey)
        check(LevelDisplay.stored(defaults.string(forKey: LevelDisplay.storageKey)) == .technical, "the chosen reading is remembered")

        // The reminder interval: every hour by default, repeating, with presets, never and a custom length.
        check(ReminderInterval.defaultMinutes == 60, "reminders repeat every hour by default")
        check(ReminderInterval.presets == [30, 60, 120, 180] && ReminderInterval.never == 0, "the presets are 30 minutes, 1, 2 and 3 hours, or never")
        let fresh = "nosy-round8-reminder-\(UUID().uuidString)"
        let reminders = try require(UserDefaults(suiteName: fresh), "a second defaults suite")
        defer { reminders.removePersistentDomain(forName: fresh) }
        check(ReminderInterval.stored(reminders) == 60, "a fresh install reads every hour")
        ReminderInterval.save(120, reminders)
        check(ReminderInterval.stored(reminders) == 120, "a chosen interval is remembered")
        ReminderInterval.save(-3, reminders)
        check(ReminderInterval.stored(reminders) == ReminderInterval.never, "a negative setting saves as never")
        ReminderInterval.save(45, reminders)
        check(ReminderInterval.stored(reminders) == 45, "a custom interval is remembered")
        check(ReminderInterval.normalized(2) == 5 && ReminderInterval.normalized(5000) == 1440 && ReminderInterval.normalized(45) == 45,
              "a custom interval stays between 5 minutes and 24 hours")
        check(ReminderInterval.label(30) == "Every 30 minutes" && ReminderInterval.label(60) == "Every hour"
              && ReminderInterval.label(120) == "Every 2 hours" && ReminderInterval.label(180) == "Every 3 hours"
              && ReminderInterval.label(ReminderInterval.never) == "Never", "the presets read in plain words")
        check(ReminderInterval.label(45) == "Every 45 minutes" && ReminderInterval.label(90) == "Every 1 hour 30 minutes"
              && ReminderInterval.label(61) == "Every 1 hour 1 minute" && ReminderInterval.label(1440) == "Every 24 hours",
              "custom intervals read in hours and minutes")
        // An hours setting from an older build carries over once, and a saved minutes value always wins.
        let legacy = "nosy-round8-legacy-\(UUID().uuidString)"
        let older = try require(UserDefaults(suiteName: legacy), "a legacy defaults suite")
        defer { older.removePersistentDomain(forName: legacy) }
        older.set(3, forKey: ReminderInterval.legacyHoursKey)
        ReminderInterval.migrate(older)
        check(ReminderInterval.stored(older) == 180, "an older 3 hour setting carries over as 180 minutes")
        older.removeObject(forKey: ReminderInterval.storageKey)
        older.set(0, forKey: ReminderInterval.legacyHoursKey)
        ReminderInterval.migrate(older)
        check(ReminderInterval.stored(older) == ReminderInterval.never, "an older never setting carries over as never")
        older.removeObject(forKey: ReminderInterval.storageKey)
        older.set(3, forKey: ReminderInterval.legacyHoursKey)
        older.set(45, forKey: ReminderInterval.storageKey)
        ReminderInterval.migrate(older)
        check(ReminderInterval.stored(older) == 45, "a saved minutes value wins over an older hours setting")

        // The Connect your AI copy and state, with Claude Desktop's state injected.
        check(ConnectionCopy.title(.added, installed: true) == "Connected to Claude Desktop", "a connected Nosy says so")
        check(ConnectionCopy.title(.notAdded, installed: false) == "Claude Desktop is not installed", "a missing Claude Desktop says so")
        check(ConnectionCopy.title(.notAdded, installed: true) == "Not connected yet", "an installed Claude Desktop without Nosy is not connected")
        check(ConnectionCopy.title(.unreadable("bad"), installed: true) == "Claude Desktop settings need fixing", "unreadable settings say so")
        check(ConnectionCopy.steps == ["Quit and reopen Claude Desktop.", "Ask: \u{201C}Summarize my latest lecture\u{201D}"],
              "the next steps are numbered in the owner's order")
        check(ConnectionCopy.examplePrompt == "Summarize my latest lecture", "the example prompt is the lecture summary question")

        let config = root.appendingPathComponent("claude_desktop_config.json")
        let helper = root.appendingPathComponent("nosy-mcp")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let installed = ClaudeDesktopApp.Status(installed: true, running: false)
        let connector = ClaudeConnector(configURL: config, helperURL: helper, desktop: { installed })
        check(connector.desktop() == installed, "the connector reports the Claude Desktop state it was given")
        check(connector.status() == .notAdded, "no Nosy entry means not connected")
        try connector.add()
        check(connector.status() == .added, "adding writes the Nosy entry and the pane shows it as connected")

        // Hyphens and dashes stay out of the copy the owner sees.
        var copy = ConnectionCopy.steps + [ConnectionCopy.connected, ConnectionCopy.notConnected, ConnectionCopy.notInstalled,
                                           ConnectionCopy.needsFixing, ConnectionCopy.closedNote, ConnectionCopy.installNote,
                                           ConnectionCopy.downloadLabel, ConnectionCopy.removedNote, ConnectionCopy.copiedPrompt]
        copy += ReminderInterval.presets.map(ReminderInterval.label) + [ReminderInterval.label(45), ReminderInterval.label(90)]
        copy += LevelDisplay.allCases.map { InputLevel.primary(-38, display: $0) } + [InputLevel.technical(-160)]
        copy += InputLevel.Band.allCases.map(\.label)
        check(copy.allSatisfy { text in !text.contains("-") && !text.contains("\u{2013}") && !text.contains("\u{2014}") },
              "UI copy uses no hyphens or dashes")
        print("transcripts settings checks: \(copy.count) strings")
    }

    static func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw LectureError.message("Could not create \(what).") }
        return value
    }
}
