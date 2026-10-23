import AppKit
import SwiftUI

@main
@MainActor
enum UITests {
    static func main() throws {
        _ = NSApplication.shared
        Snapshot.isRunning = true
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("Nosy-ui-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("NOSY_SUPPORT_DIR", root.appendingPathComponent("support").path, 1)
        setenv("NOSY_TRANSCRIPTS_DIR", root.appendingPathComponent("transcripts").path, 1)
        let model = AppModel()
        let paths = model.paths
        try paths.prepareSupport()
        let folder = paths.lectureFolder("MBB322")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("First.md")
        let second = folder.appendingPathComponent("Second.md")
        let speech = "# MBB322\n\n## Transcript\n\nATP helps cells.\n\n> [0:01] Exam hint\n"
        try speech.write(to: first, atomically: true, encoding: .utf8)
        try speech.write(to: second, atomically: true, encoding: .utf8)
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
        let library = TranscriptLibrary()
        library.didChange = { old, new in model.transcriptChanged(from: old, to: new) }
        library.reload(paths: paths)
        library.select(first)
        check(library.selected != nil, "Selection must resolve before editing")
        library.beginEditing(paths: paths)
        check(library.editing, "Editing must begin")
        library.draft = speech + "Edited."
        library.chooseDraftAction = { .cancel }
        library.open(second, paths: paths)
        check(library.selection == first && library.editing && library.draft.hasSuffix("Edited."), "External Open must retain a cancelled dirty draft")
        library.reload(paths: paths)
        check(library.editing && library.draft.hasSuffix("Edited."), "Activation reload must retain dirty text")
        library.chooseDraftAction = { .save }
        library.open(second, paths: paths)
        check(library.selection == second && !library.editing, "Save then navigate")
        check(try String(contentsOf: first, encoding: .utf8) == speech + "Edited.", "Save targets the original draft file")
        library.beginEditing(paths: paths)
        library.draft = "Discard me"
        library.chooseDraftAction = { .discard }
        library.select(first)
        check(try String(contentsOf: second, encoding: .utf8) == speech, "Discard does not write")
        library.beginEditing(paths: paths)
        library.draft = "Keep this in the original folder"
        library.chooseDraftAction = { .cancel }
        let other = AppPaths(environment: ["NOSY_SUPPORT_DIR": paths.support.path, "NOSY_TRANSCRIPTS_DIR": root.appendingPathComponent("other").path])
        library.reload(paths: other)
        check(library.selection == first && library.editing, "Folder changes must guard dirty edits")
        library.chooseDraftAction = { .save }
        library.reload(paths: other)
        check(try String(contentsOf: first, encoding: .utf8) == "Keep this in the original folder", "Folder changes save to captured paths")
        model.selectedLecture = "MBB322"
        check(model.vocabularySubject == "Biology", "Ready resolves the configured subject")
        try SubjectSettings(subject: "off").save(folder: folder)
        check(model.vocabularySubject == "None", "Subject off is None")
        model.configurePreview()
        check(model.inputName == "MacBook Pro Microphone", "Idle mic has no routing or dB suffix")
        check(!AudioInputs.isUserVisible(.init(id: "proxy", name: "CADefaultDeviceAggregate-45310-0")), "Hide the private CoreAudio proxy")
        check(AudioInputs.isUserVisible(.init(id: "user-aggregate", name: "My Studio Aggregate")), "Keep intentional aggregates")
        var record = SessionRecord(id: "test", lecture: "MBB322", session: "First", startedAt: Date(), status: .done,
                                   transcriptPath: first.path, vocabularyTerms: ["ATP"])
        model.current = record
        library.reload(paths: paths)
        library.select(first)
        _ = library.save(speech, to: first, paths: paths)
        check(model.savedSummary.words == 3 && model.savedSummary.vocabHits == 1, "Edits refresh Saved words, copy text and hits")
        try "unrelated".write(to: folder.appendingPathComponent("vocab.txt"), atomically: true, encoding: .utf8)
        model.refreshSavedTranscript()
        check(model.savedSummary.terms == 1 && model.savedSummary.vocabHits == 1, "Later vocabulary changes cannot alter historical hits")
        let renamed = folder.appendingPathComponent("Renamed.md")
        try FileManager.default.moveItem(at: first, to: renamed)
        model.transcriptChanged(from: first, to: renamed)
        check(model.current?.transcriptPath == renamed.path && model.savedSummary.markdown == speech, "Rename refreshes Saved actions")
        try FileManager.default.removeItem(at: renamed)
        model.transcriptChanged(from: renamed, to: nil)
        check(model.savedSummary.markdown == nil && model.current?.transcriptPath == nil, "Trash disables Saved actions and clears copy cache")
        let empty = "# Empty\n\n## Transcript\n\n> [0:01] A marker\n\n_No speech detected._\n"
        try empty.write(to: first, atomically: true, encoding: .utf8)
        record.transcriptPath = first.path
        model.current = record
        check(model.savedSummary.noSpeech && model.savedSummary.words == 0, "Silent recordings with markers are neutral no-speech outcomes")
        check(Core.wordCount("# Empty\n\n## Transcript\n\n") == 0, "Empty transcript body has zero words")
        check(Core.wordCount("An edited transcript without headings") == 5, "Removing a heading must not turn speech into a silent outcome")
        try record.save(in: paths)
        check(try SessionRecord.read(paths.audioFile(record.id, "json")).vocabularyTerms == ["ATP"], "Captured vocabulary survives sidecar roundtrip")
        print("UI REGRESSION PASS: dirty navigation, folder changes, Saved invalidation, silence, subjects, mic labels and historical vocabulary")
    }
}
