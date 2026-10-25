import Foundation

// Transcripts tree rules: folders open and close, search opens matches, the selected
// transcript's folder is revealed, open folders persist, and silent transcripts read cleanly.
@main
@MainActor
enum LibraryTests {
    static func main() {
        do {
            try run()
            print("LIBRARY TESTS PASS: folder tree, search, remembered folders, no-speech reader")
        } catch {
            FileHandle.standardError.write(Data("LIBRARY TEST FAILED: \(error)\n".utf8))
            exit(1)
        }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("LIBRARY TEST FAILED: \(message)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        // Folder state on its own.
        var folders = TranscriptFolders()
        check(!folders.isOpen("A", searching: false), "folders start closed")
        folders.toggle("A", searching: false)
        check(folders.isOpen("A", searching: false), "a click opens a closed folder")
        folders.toggle("A", searching: false)
        check(!folders.isOpen("A", searching: false), "a click closes an open folder")
        folders.reveal("B")
        folders.reveal("B")
        check(folders.isOpen("B", searching: false), "reveal opens a folder and keeps it open")
        check(folders.isOpen("A", searching: true), "a search opens every folder it matches")
        folders.toggle("A", searching: true)
        check(!folders.isOpen("A", searching: true) && !folders.isOpen("A", searching: false),
              "closing a folder during a search leaves the saved choice alone")
        folders.endSearch()
        check(folders.isOpen("A", searching: true) && !folders.isOpen("A", searching: false),
              "clearing a search restores the saved choice")

        // Library rules on real files.
        // /private/tmp matches the paths folder enumeration returns (/var resolves to /private/var), as UITests does.
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("Nosy-library-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(environment: ["NOSY_SUPPORT_DIR": root.appendingPathComponent("support").path,
                                           "NOSY_TRANSCRIPTS_DIR": root.appendingPathComponent("transcripts").path])
        try paths.prepareSupport()
        let mbb = paths.lectureFolder("MBB322")
        let chem = paths.lectureFolder("CHEM281")
        try FileManager.default.createDirectory(at: mbb, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chem, withIntermediateDirectories: true)
        let now = Date()
        let newest = mbb.appendingPathComponent("2026-10-23.md")
        let older = mbb.appendingPathComponent("2026-10-20.md")
        let chemistry = chem.appendingPathComponent("2026-10-21.md")
        try "# MBB322\n\n## Transcript\n\nATP drives work.\n".write(to: newest, atomically: true, encoding: .utf8)
        try "# MBB322\n\n## Transcript\n\nEnzymes lower activation energy.\n".write(to: older, atomically: true, encoding: .utf8)
        try "# CHEM281\n\n## Transcript\n\nTitration endpoints.\n".write(to: chemistry, atomically: true, encoding: .utf8)
        for (url, age) in [(newest, 0.0), (older, -172_800), (chemistry, -86_400)] {
            try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(age)], ofItemAtPath: url.path)
        }

        let library = TranscriptLibrary()
        library.reload(paths: paths)
        check(library.selection == newest, "the newest transcript opens selected")
        check(library.importTargetLecture == "MBB322", "the selected transcript sets the import folder")
        check(library.isOpen("MBB322") && !library.isOpen("CHEM281"), "the selected folder starts open and the others closed")
        check(library.visibleRows.map(\.url) == [newest, older], "closed folders hide their sessions")

        library.selectFolder("CHEM281")
        check(library.importTargetLecture == "CHEM281", "the selected tree folder overrides the main folder")
        library.selectFolder("MBB322")
        library.toggleFolder("CHEM281")
        check(library.visibleRows.map(\.url) == [chemistry, newest, older], "an opened folder shows its sessions in order")
        library.toggleFolder("MBB322")
        check(library.visibleRows.map(\.url) == [chemistry], "clicking an open folder collapses it")

        // Arrow keys step through what is on screen, even from a transcript in a closed folder.
        library.toggleFolder("MBB322")
        library.select(newest)
        library.toggleFolder("MBB322")
        check(library.selection == newest && !library.isOpen("MBB322"), "a collapsed folder keeps the reader's transcript")
        library.move(1)
        check(library.selection == chemistry, "arrow keys move through visible rows only")

        // Selecting a transcript reveals its folder.
        library.select(older)
        check(library.isOpen("MBB322") && library.selection == older, "selecting a transcript opens its folder")
        library.toggleFolder("MBB322")
        library.select(chemistry)
        library.toggleFolder("CHEM281")
        library.select(newest)
        check(library.isOpen("MBB322") && library.selection == newest, "selecting from a closed folder reveals it")

        // Search opens matching folders, and clearing it returns to the saved choice.
        library.toggleFolder("MBB322")
        library.toggleFolder("CHEM281")
        check(!library.isOpen("MBB322") && library.isOpen("CHEM281"), "setup: MBB322 closed and CHEM281 open before searching")
        library.query = "ATP"
        check(library.isOpen("MBB322") && library.grouped.map { $0.lecture } == ["MBB322"],
              "search opens the folder with matches and hides folders without them")
        check(library.visibleRows.map(\.url) == [newest], "search shows only matching sessions")
        library.toggleFolder("MBB322")
        check(!library.isOpen("MBB322") && library.visibleRows.isEmpty, "a folder closed during search stays closed")
        library.query = ""
        check(!library.isOpen("MBB322") && library.isOpen("CHEM281"), "clearing search restores the saved folders")
        check(library.selection == newest, "clearing search keeps the selected transcript")

        // Open folders are remembered across launches; the main window's list does not save them.
        let suiteName = "nosy.library-tests.\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suiteName), "test defaults suite")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = TranscriptLibrary()
        first.restoreFolders(from: defaults)
        first.reload(paths: paths)
        first.toggleFolder("CHEM281")
        let relaunched = TranscriptLibrary()
        relaunched.restoreFolders(from: defaults)
        relaunched.reload(paths: paths)
        check(relaunched.isOpen("CHEM281") && relaunched.isOpen("MBB322"), "open folders are remembered across launches")
        let unsaved = TranscriptLibrary()
        unsaved.reload(paths: paths)
        check(unsaved.isOpen("MBB322") && !unsaved.isOpen("CHEM281"), "a window without storage keeps folder state in memory only")

        // Silent transcripts read as a clean line, not raw Markdown.
        let silent = "# MBB322\n\n## Transcript\n\n_No speech detected._\n"
        let paragraphs = TranscriptBlock.parse(silent).compactMap { block -> String? in
            if case .paragraph(let text) = block.content { return text }
            return nil
        }
        check(paragraphs.count == 1 && TranscriptDisplay.isNoSpeech(paragraphs[0]), "a silent transcript's body is recognised")
        check(!TranscriptDisplay.isNoSpeech("Not quite _No speech detected._ here"), "only a whole silent body counts")
        check(!TranscriptDisplay.isNoSpeech("ATP helps cells."), "speech is not silent")
        let onDisk = try String(contentsOf: newest, encoding: .utf8)
        check(onDisk.contains("ATP drives work."), "reading never rewrites transcripts")
    }

    static func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw LibraryTestError.missing(what) }
        return value
    }
}

enum LibraryTestError: Error {
    case missing(String)
}
