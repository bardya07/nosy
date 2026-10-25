import Foundation

// Session name gate, the dB readout, and the folder Trash path. The Trash step goes through a
// fake mover, so these tests never move anything into the owner's real Trash.
@main
@MainActor
enum MainControlsTests {
    static func main() {
        do {
            try run()
            print("MAIN CONTROLS TESTS PASS: session gate, dB readout, folder trash path")
        } catch {
            FileHandle.standardError.write(Data("MAIN CONTROLS TEST FAILED: \(error)\n".utf8))
            exit(1)
        }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("MAIN CONTROLS TEST FAILED: \(message)\n".utf8))
            exit(1)
        }
    }

    final class MoveLog {
        var moved: [String] = []
    }

    static func run() throws {
        // Start needs a session name: the gate opens on request and clears once a name is typed.
        var gate = SessionNameGate()
        check(!gate.required, "the session gate starts open")
        gate.request()
        check(gate.required, "Start without a name turns the requirement on")
        gate.sessionChanged(to: "   ")
        check(gate.required, "a blank session does not satisfy the gate")
        gate.sessionChanged(to: "2026-10-25")
        check(!gate.required, "typing a session name clears the gate")
        check(SessionNameGate.message == "Name this session first", "the gate says what to do")

        // The live dB stat: whole decibels, a true minus sign, and silence as minus infinity.
        let minus = "\u{2212}"
        check(InputLevel.technical(-23.4) == "\(minus)23 dBFS", "a level of -23.4 reads as minus 23 dBFS")
        check(InputLevel.technical(-23.6) == "\(minus)24 dBFS", "readings round to the nearest decibel")
        check(InputLevel.technical(0.4) == "0 dBFS", "a reading at full scale never shows a positive number")
        check(InputLevel.technical(-160) == "\(minus)\u{221E} dBFS", "the silent sentinel reads as minus infinity")
        check(InputLevel.technical(-99.6) == "\(minus)\u{221E} dBFS", "a level below -99 reads as silence")
        check(InputLevel.technical(.nan) == "\(minus)\u{221E} dBFS", "a missing reading never prints nan")
        // The estimate is the everyday sound level, with the calibration offset, clamped to the meter's range.
        check(InputLevel.estimateText(-23.4) == "\u{2248} 71 dB", "the estimate adds the calibration offset")
        check(InputLevel.estimateText(-160) == "\u{2248} 20 dB", "silence estimates at the bottom of the range")
        check(InputLevel.band(-160) == .quiet && InputLevel.band(-23.4) == .good && InputLevel.band(-5) == .loud, "the Quiet, Good and Loud bands")
        check(InputLevel.primary(-23.4, display: .estimate) == "\u{2248} 71 dB" && InputLevel.primary(-23.4, display: .technical) == "\(minus)23 dBFS",
              "the chosen display sets the first readout")
        check(InputLevel.fraction(-60) == 0 && InputLevel.fraction(0) == 1, "the meter runs from -60 to 0 dB")
        check(abs(InputLevel.fraction(-30) - 0.5) < 0.0001, "the meter is linear in decibels")
        check(InputLevel.fraction(-160) == 0 && InputLevel.fraction(12) == 1, "the meter stays inside its bar")

        // Deleting a folder: only folders inside the library, moved through the Trash mover.
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("Nosy-trash-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(environment: ["NOSY_SUPPORT_DIR": root.appendingPathComponent("support").path,
                                           "NOSY_TRANSCRIPTS_DIR": root.appendingPathComponent("transcripts").path])
        try paths.prepareSupport()
        let mbb = paths.lectureFolder("MBB322")
        try FileManager.default.createDirectory(at: mbb, withIntermediateDirectories: true)
        try "# MBB322\n\n## Transcript\n\nATP drives work.\n"
            .write(to: mbb.appendingPathComponent("2026-10-23.md"), atomically: true, encoding: .utf8)
        try "loose".write(to: paths.transcripts.appendingPathComponent("Loose.md"), atomically: true, encoding: .utf8)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.lectureFolder("Linked"), withDestinationURL: outside)

        let log = MoveLog()
        try LectureFolderTrash.move("MBB322", paths: paths, mover: { log.moved.append($0.path) })
        check(log.moved == [mbb.path], "a confirmed folder inside the library is the one moved to the Trash")

        for name in ["../outside", "a/b", "", "."] {
            let before = log.moved.count
            var refused = false
            do { try LectureFolderTrash.move(name, paths: paths, mover: { log.moved.append($0.path) }) }
            catch { refused = true }
            check(refused && log.moved.count == before, "the name \"\(name)\" is refused and never moved")
        }
        for name in ["Missing", "Loose.md", "Linked"] {
            let before = log.moved.count
            var refused = false
            do { try LectureFolderTrash.move(name, paths: paths, mover: { log.moved.append($0.path) }) }
            catch { refused = true }
            check(refused && log.moved.count == before, "\"\(name)\" is not a folder inside the library and is refused")
        }
        check(FileManager.default.fileExists(atPath: outside.path), "the folder a link points to is never touched")

        // A failed Trash surfaces as an error, and the folder is still there.
        var failed = false
        do {
            try LectureFolderTrash.move("MBB322", paths: paths, mover: { _ in throw LectureError.message("Trash refused") })
        } catch { failed = true }
        check(failed && FileManager.default.fileExists(atPath: mbb.path), "a failed Trash leaves the folder in place")

        print("MAIN CONTROLS CHECKS: \(log.moved.count) folder moved through the fake Trash")
    }
}
