import AppKit
import SwiftUI

@main
@MainActor
enum UITests {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fail("\(error)") }
        }
        NSApp.run()
    }

    static func run() async throws {
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
        try FileManager.default.createDirectory(at: paths.lectureFolder("CHEM281"), withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("First.md")
        let second = folder.appendingPathComponent("Second.md")
        let speech = "# MBB322\n\n- Date: 2026-10-23\n- Length: 1 min\n\n## Transcript\n\nATP helps cells.\n\n> [0:01] Exam hint\n"
        try speech.write(to: first, atomically: true, encoding: .utf8)
        try speech.write(to: second, atomically: true, encoding: .utf8)
        func check(_ condition: Bool, _ message: String) { expect(condition, message) }
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
        library.draft = speech + "Keep this in the original folder"
        library.chooseDraftAction = { .cancel }
        let other = AppPaths(environment: ["NOSY_SUPPORT_DIR": paths.support.path, "NOSY_TRANSCRIPTS_DIR": root.appendingPathComponent("other").path])
        library.reload(paths: other)
        check(library.selection == first && library.editing, "Folder changes must guard dirty edits")
        library.chooseDraftAction = { .save }
        library.reload(paths: other)
        check(try String(contentsOf: first, encoding: .utf8) == speech + "Keep this in the original folder", "Folder changes save to captured paths")
        model.selectedLecture = "MBB322"
        check(model.vocabularySubject == "Biology", "Ready resolves the configured subject")
        let unopenedSettings = folder.appendingPathComponent("vocabulary.json")
        let autoDraft = VocabularyDraft(lecture: "MBB322", folder: folder, didSave: {})
        autoDraft.flush()
        check(!FileManager.default.fileExists(atPath: unopenedSettings.path), "opening and closing Auto never persists a guessed subject")
        autoDraft.text = "ATP"
        autoDraft.flush()
        check(try SubjectSettings.load(folder: folder).subject == "auto", "Auto term autosave stores Auto, never Chemistry or a guessed subject")
        try SubjectSettings(subject: "chemistry").save(folder: folder)
        let chemistryDraft = VocabularyDraft(lecture: "MBB322", folder: folder, didSave: {})
        check(chemistryDraft.subjects.subject == "chemistry", "the editor loads explicit Chemistry without running Auto")
        chemistryDraft.text = "NADH"
        chemistryDraft.flush()
        check(try SubjectSettings.load(folder: folder).subject == "chemistry", "term autosave preserves the explicit Chemistry choice")
        try SubjectSettings(subject: "general").save(folder: folder)
        check(model.vocabularySubject == "General", "General disables subject vocabulary")
        // Rapid edits coalesce; dismissal flushes the latest value to the captured
        // folder even if the Ready window has since selected another folder.
        var writes: [(String, SubjectSettings?)] = []
        let draft = VocabularyDraft(lecture: "MBB322", text: "") { text, settings in
            writes.append((text, settings))
        }
        draft.text = "ATP"
        draft.text = "ATP, NADH\n"
        check(writes.isEmpty, "typing is debounced")
        try await Task.sleep(for: .milliseconds(500))
        check(writes.count == 1 && writes[0].0 == "ATP, NADH\n", "debounce saves the exact latest text once")
        draft.text += "acetyl-CoA"
        draft.subjects = SubjectSettings(subject: "chemistry")
        draft.flush()
        check(writes.count == 2 && writes.last?.0 == draft.text && writes.last?.1?.subject == "chemistry", "close flushes pending text and subject together")
        try await Task.sleep(for: .milliseconds(450))
        check(writes.count == 2 && !draft.hasChanges, "flushed debounce cannot write again")
        var failWrite = true
        let retained = VocabularyDraft(lecture: "MBB322", text: "") { _, _ in
            if failWrite { throw LectureError.message("Test write failure") }
        }
        retained.text = "Keep this text"
        retained.flush()
        check(retained.hasChanges && retained.saveError != nil && retained.text == "Keep this text", "failed writes retain the dirty draft for reopening")
        failWrite = false
        retained.flush()
        check(!retained.hasChanges && retained.saveError == nil, "retained drafts can retry")
        var repairedSettings: SubjectSettings?
        let repair = VocabularyDraft(lecture: "MBB322", text: "", subjects: SubjectSettings(subject: "general"), settingsError: "Invalid settings") { _, settings in
            repairedSettings = settings
        }
        repair.selectSubject("general")
        repair.flush()
        check(repairedSettings?.subject == "general" && repair.settingsError == nil, "selecting General repairs settings when it is already selected")
        let captured = VocabularyDraft(lecture: "MBB322", folder: folder, didSave: {})
        model.selectedLecture = "CHEM281"
        captured.text = "  ATP, NADH\n"
        captured.flush()
        check(try String(contentsOf: folder.appendingPathComponent("vocab.txt"), encoding: .utf8) == captured.text, "close writes exact text into the original folder")
        check(!FileManager.default.fileExists(atPath: paths.lectureFolder("CHEM281").appendingPathComponent("vocab.txt").path), "switching folders cannot redirect a pending save")
        model.selectedLecture = "MBB322"
        model.configurePreview()
        check(model.inputName == "MacBook Pro Microphone", "Idle mic has no routing or dB suffix")

        let sharedModel = AppModel.shared
        library.reload(paths: paths)
        _ = library.select(first)
        library.beginEditing(paths: paths)
        library.draft = speech + "Unsaved before quit."
        library.chooseDraftAction = { .cancel }
        sharedModel.finishLibraryEditing = { library.finishEditing() }
        check(AppDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,
              "Quit asks about dirty transcript edits before terminating")
        let textAfterCancelledQuit = try String(contentsOf: first, encoding: .utf8)
        check(library.editing && textAfterCancelledQuit == speech + "Keep this in the original folder",
              "cancelled Quit retains the unsaved transcript draft")
        library.chooseDraftAction = { .save }
        check(AppDelegate().applicationShouldTerminate(NSApp) == .terminateNow,
              "Quit proceeds after saving transcript edits")
        check(try String(contentsOf: first, encoding: .utf8) == speech + "Unsaved before quit.",
              "Quit saves the edited transcript to its original file")
        library.beginEditing(paths: paths)
        library.draft += " Save failure."
        sharedModel.finishLibraryEditing = { false }
        check(AppDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,
              "Quit is cancelled when saving transcript edits fails")
        sharedModel.finishLibraryEditing = nil

        let hiddenFolder = paths.transcripts.appendingPathComponent(".Private", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: true)
        let hiddenTranscript = hiddenFolder.appendingPathComponent(".Session.md")
        try (speech + "Hidden draft remains discoverable").write(to: hiddenTranscript, atomically: true, encoding: .utf8)
        check(paths.lectures().contains(".Private"), "existing hidden transcript folders remain in the save folder list")
        library.reload(paths: paths)
        check(library.items.contains(where: { $0.url == hiddenTranscript }), "existing hidden transcripts remain discoverable")

        check(!AudioInputs.isUserVisible(.init(id: "proxy", name: "CADefaultDeviceAggregate-45310-0")), "Hide the private CoreAudio proxy")
        check(AudioInputs.isUserVisible(.init(id: "user-aggregate", name: "My Studio Aggregate")), "Keep intentional aggregates")
        let previousSource = UserDefaults.standard.string(forKey: "recordingSource")
        defer { UserDefaults.standard.set(previousSource, forKey: "recordingSource") }
        if RecordingSource.macAudioAvailable {
            model.selectSource(.macAudio)
            check(model.inputName == "Mac audio", "Mac source label")
            check(AppModel().recordingSource == .macAudio, "Remember the source")
            model.phase = .recording
            model.paused = false
            check(model.micLocked, "Recording locks the source mode and microphone menu")
            model.selectSource(.both)
            check(model.recordingSource == .macAudio, "Active recording locks source changes")
            model.paused = true
            check(!model.micLocked, "Pausing unlocks source mode and microphone selection")
            model.transitioning = true
            model.selectSource(.both)
            check(model.recordingSource == .macAudio, "Transitions lock source changes even when paused")
            model.transitioning = false
            model.selectSource(.both)
            check(model.inputName == "MacBook Pro Microphone + Mac audio", "Paused source changes and Both label")
            check(AppModel().recordingSource == .both, "Mac audio mode choice is remembered")
            model.phase = .idle
            model.paused = false
            model.selectSource(.mic)
        }
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
        let empty = "# Empty\n\n- Date: 2026-10-23\n- Length: 1 min\n\n## Transcript\n\n> [0:01] A marker\n\n_No speech detected._\n"
        try empty.write(to: first, atomically: true, encoding: .utf8)
        record.transcriptPath = first.path
        model.current = record
        check(model.savedSummary.noSpeech && model.savedSummary.words == 0, "Silent recordings with markers are neutral no-speech outcomes")
        check(Core.wordCount("# Empty\n\n- Date: 2026-10-23\n- Length: 1 min\n\n## Transcript\n\n") == 0, "Empty transcript body has zero words")
        check(Core.wordCount("An edited transcript without headings") == 5, "Removing a heading must not turn speech into a silent outcome")
        try record.save(in: paths)
        check(try SessionRecord.read(paths.audioFile(record.id, "json")).vocabularyTerms == ["ATP"], "Captured vocabulary survives sidecar roundtrip")
        model.phase = .idle
        model.configurePreview()
        model.session = ""
        model.refreshLectures()
        model.selectedLecture = "MBB322"
        let validationRequest = model.startValidationRequest
        model.start()
        check(model.startValidationRequest == validationRequest + 1 && model.phase == .idle && !model.transitioning,
              "An empty session is gated before any recording work begins")
        // Tips are placed on the window's own bounds: whole, two lines at most, from every anchor.
        let frameSize = CGSize(width: 400, height: 300)
        let tipTexts = ["Start recording", "All transcripts", "Change where transcripts are saved", "Open setup",
                        "Pick a subject or setting to fine tune the vocabulary.", "Use today's date"]
        for text in tipTexts {
            for edge in [VerticalEdge.top, .bottom] {
                for x in stride(from: CGFloat(0), through: frameSize.width, by: 20) {
                    for y in stride(from: CGFloat(0), through: frameSize.height, by: 15) {
                        let anchor = CGRect(x: x - 10, y: y - 8, width: 20, height: 16)
                        let layout = TipPlacement.layout(text: text, edge: edge, anchor: anchor, container: frameSize)
                        let box = CGRect(x: layout.center.x - layout.size.width / 2, y: layout.center.y - layout.size.height / 2,
                                         width: layout.size.width, height: layout.size.height)
                        let margin = TipPlacement.margin
                        check(box.minX >= margin - 0.01 && box.maxX <= frameSize.width - margin + 0.01
                              && box.minY >= margin - 0.01 && box.maxY <= frameSize.height - margin + 0.01,
                              "Tip \"\(text)\" leaves the window at \(x), \(y) \(edge)")
                        // Text that needs a third line would be cut off, so it must fit two.
                        check(ceil(TipPlacement.wrappedHeight(text, width: layout.size.width)) <= 2 * TipPlacement.lineHeight + 1,
                              "Tip \"\(text)\" needs more than two lines")
                    }
                }
            }
        }
        try await MainWindowInteraction.run(model: model)
        try await AppLifecycleTests.run()
        print("UI REGRESSION PASS: dirty navigation, folder changes, Saved invalidation, silence, subjects, mic labels and historical vocabulary")
    }
}
