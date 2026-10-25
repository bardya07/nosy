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

// Moving a folder to the Trash. Only a folder inside the transcript library can be moved,
// and the move is the system Trash, so it stays recoverable.
enum LectureFolderTrash {
    typealias Mover = (URL) throws -> Void

    static func move(_ lecture: String, paths: AppPaths,
                     mover: Mover = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        try paths.validateLectureFolder(lecture)
        let folder = paths.lectureFolder(lecture)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              Core.isContained(folder, in: paths.transcripts) else {
            throw LectureError.message("That folder is no longer in your transcript library.")
        }
        try mover(folder)
    }
}
