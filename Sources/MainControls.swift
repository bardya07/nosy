import AppKit
import Foundation

// Pure rules behind the main window's controls, so tests can check them without a window.

// Start needs a session name. Asking for one turns the red line on; typing a name turns it off.
struct SessionNameGate: Equatable {
    static let message = "Name this session first"
    private(set) var required = false

    mutating func request() { required = true }

    mutating func sessionChanged(to name: String) {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { required = false }
    }
}

// Level readouts for the live input meter. Silence reads as minus infinity, never as a number.
enum InputLevel {
    static let silent = -160.0

    static func readout(_ decibels: Double) -> String {
        guard decibels.isFinite else { return "\u{2212}\u{221E} dB" }
        let rounded = Int(decibels.rounded())
        if rounded <= -100 { return "\u{2212}\u{221E} dB" }
        if rounded >= 0 { return "0 dB" }
        // A true minus sign, not a hyphen, so the stat reads as a level in the window.
        return "\u{2212}\(-rounded) dB"
    }

    // Bar length for the meter: -60 dB is empty and 0 dB is full.
    static func fraction(_ decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels + 60) / 60))
    }
}

// Deleting a folder: the one path both the main window and the Transcripts window use. Only a folder
// directly inside the transcript library can move, the move is the system Trash so it stays
// recoverable, and the owner confirms first.
enum LectureFolderTrash {
    typealias Mover = (URL) throws -> Void

    static func systemTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    static func move(_ lecture: String, paths: AppPaths, mover: Mover = LectureFolderTrash.systemTrash) throws {
        try paths.validateLectureFolder(lecture)
        let folder = paths.lectureFolder(lecture)
        // Compare normalized paths only; the mover gets the folder exactly as the library spells it.
        let root = paths.transcripts.resolvingSymlinksInPath().standardizedFileURL
        let parent = folder.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        // A link that points outside the library fails the containment check, so its target is never moved.
        guard parent == root, Core.isContained(folder, in: paths.transcripts),
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LectureError.message("That folder is no longer in your transcript library.")
        }
        try mover(folder)
    }

    // The one confirmation for deleting a folder. Cancel is the default so a stray Return never moves it.
    @MainActor static func confirm(_ lecture: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move \"\(lecture)\" and its transcripts to the Trash?"
        let trash = alert.addButton(withTitle: "Move to Trash")
        trash.hasDestructiveAction = true
        trash.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
