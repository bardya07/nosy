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
        try "# MBB322\n\n- Date: 2026-10-23\n- Length: 1 min\n\n## Transcript\n\nATP drives work.\n".write(to: newest, atomically: true, encoding: .utf8)
        try "# MBB322\n\n- Date: 2026-10-23\n- Length: 1 min\n\n## Transcript\n\nEnzymes lower activation energy.\n".write(to: older, atomically: true, encoding: .utf8)
        try "# CHEM281\n\n- Date: 2026-10-23\n- Length: 1 min\n\n## Transcript\n\nTitration endpoints.\n".write(to: chemistry, atomically: true, encoding: .utf8)
        for (url, age) in [(newest, 0.0), (older, -172_800), (chemistry, -86_400)] {
            try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(age)], ofItemAtPath: url.path)
        }

        // Unrelated markdown beside transcripts (a destination like ~/Downloads) is never listed.
        let random = paths.transcripts.appendingPathComponent("Hamstr stuff")
        try FileManager.default.createDirectory(at: random, withIntermediateDirectories: true)
        try "# MB v1.22\n\nRelease notes.\n".write(to: random.appendingPathComponent("MB-v1.22.md"), atomically: true, encoding: .utf8)
        try "# HANDOFF\n\n## Transcript\n\nNot a Nosy file.\n".write(to: mbb.appendingPathComponent("HANDOFF.md"), atomically: true, encoding: .utf8)
        try "# STATUS\n".write(to: paths.transcripts.appendingPathComponent("STATUS.md"), atomically: true, encoding: .utf8)

        let library = TranscriptLibrary()
        library.reload(paths: paths)
        check(Set(library.items.map(\.url)) == [newest, older, chemistry], "only Nosy transcripts are listed, never other markdown")
        check(!library.grouped.map(\.lecture).contains("Hamstr stuff"), "a folder without transcripts gets no group")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try String(contentsOf: newest, encoding: .utf8).write(to: outside.appendingPathComponent("Owner.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: paths.lectureFolder("Outside"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: mbb.appendingPathComponent("Outside.md"), withDestinationURL: outside.appendingPathComponent("Owner.md"))
        library.reload(paths: paths)
        check(!library.items.contains { $0.session == "Owner" || $0.session == "Outside" }, "outside symlinks are not listed")
        check(!paths.lectures().contains("Outside"), "outside symlinks are not offered as save folders")
        var refused = false
        do { try paths.validateLectureFolder("Outside") } catch { refused = true }
        check(refused, "recording or importing cannot write through an outside symlink")
        check(Core.isTranscript("# MBB322 — 2026-10-23\r\n\r\n- Date: 2026-10-23\r\n- Started: 16:13\r\n- Length: 52 min\r\n\r\n## Transcript\r\n\r\nText"),
              "a real header with CRLF line endings is a transcript")
        check(!Core.isTranscript("Notes\n# Heading\n- Date: x\n- Length: y\n## Transcript"), "the title must come first")

        // A chosen destination gets its own "Nosy Transcripts" folder; Nosy libraries stay as they are.
        let home = root.appendingPathComponent("home", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads.appendingPathComponent("MB"), withIntermediateDirectories: true)
        try "# STATUS\n".write(to: downloads.appendingPathComponent("MB/STATUS.md"), atomically: true, encoding: .utf8)
        check(AppPaths.dedicatedTranscripts(for: downloads, home: home).path == downloads.standardizedFileURL.appendingPathComponent("Nosy Transcripts").path,
              "choosing Downloads stores transcripts in Downloads/Nosy Transcripts")
        let dedicated = downloads.appendingPathComponent("Nosy Transcripts", isDirectory: true)
        check(AppPaths.dedicatedTranscripts(for: dedicated, home: home).path == dedicated.standardizedFileURL.path, "choosing the dedicated folder keeps it")
        let legacy = home.appendingPathComponent("Desktop/Lecture Transcripts", isDirectory: true)
        check(AppPaths.dedicatedTranscripts(for: legacy, home: home).path == legacy.standardizedFileURL.path, "the old Lecture Transcripts folder keeps working")
        check(AppPaths.dedicatedTranscripts(for: paths.transcripts, home: home).path == paths.transcripts.standardizedFileURL.path,
              "a folder that already holds Nosy transcripts is used as is")
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("Course"), withIntermediateDirectories: true)
        try String(contentsOf: newest, encoding: .utf8).write(to: legacy.appendingPathComponent("Course/Existing.md"), atomically: true, encoding: .utf8)
        let locations = AppPaths.libraryLocations(current: dedicated, previous: [paths.transcripts.path, legacy.path], home: home)
        check(locations == [dedicated, paths.transcripts, legacy], "current, previous and legacy libraries remain reachable without duplicates")
        check(paths.browsingLibrary(at: legacy).transcripts == legacy && paths.browsingLibrary(at: legacy).audio == paths.audio,
              "browsing an older library preserves the audio support location")
        let downloadsNames = try FileManager.default.contentsOfDirectory(atPath: downloads.path).sorted()
        check(downloadsNames == ["MB"], "choosing a folder moves or creates nothing by itself")
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
        let silent = "# MBB322\n\n- Date: 2026-10-23\n- Length: 1 min\n\n## Transcript\n\n_No speech detected._\n"
        let paragraphs = TranscriptBlock.parse(silent).compactMap { block -> String? in
            if case .paragraph(let text) = block.content { return text }
            return nil
        }
        check(paragraphs.count == 1 && TranscriptDisplay.isNoSpeech(paragraphs[0]), "a silent transcript's body is recognised")
        check(!TranscriptDisplay.isNoSpeech("Not quite _No speech detected._ here"), "only a whole silent body counts")
        check(!TranscriptDisplay.isNoSpeech("ATP helps cells."), "speech is not silent")
        let onDisk = try String(contentsOf: newest, encoding: .utf8)
        check(onDisk.contains("ATP drives work."), "reading never rewrites transcripts")
        library.query = ""
        library.reload(paths: paths)
        let item = try require(library.items.first(where: { $0.url == newest }), "rename fixture")
        let summary = SummaryFiles.document(body: "## Notes\nUseful notes.", transcript: newest, provider: .ollama)
        try SummaryFiles.save(summary, for: newest, expectedText: onDisk)
        let unrelatedSummary = mbb.appendingPathComponent("Renamed summary.md")
        try Data("Owner note".utf8).write(to: unrelatedSummary)
        var record = SessionRecord(id: "rename", lecture: "MBB322", session: item.session, startedAt: now, status: .done, transcriptPath: newest.path)
        try record.save(in: paths)
        try library.rename(item, to: "Renamed", paths: paths)
        let renamed = mbb.appendingPathComponent("Renamed-2.md")
        record = try SessionRecord.read(paths.audioFile(record.id, "json"))
        check(library.selection == renamed && record.transcriptPath == renamed.path, "rename keeps selection and the recording sidecar together")
        check(SummaryFiles.existing(for: renamed) != nil && !FileManager.default.fileExists(atPath: SummaryFiles.url(for: newest).path), "rename carries the matching summary")
        let preservedNote = try String(contentsOf: unrelatedSummary, encoding: .utf8)
        check(preservedNote == "Owner note", "rename never overwrites a colliding summary name")
    }

    static func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw LibraryTestError.missing(what) }
        return value
    }
}

enum LibraryTestError: Error {
    case missing(String)
}
