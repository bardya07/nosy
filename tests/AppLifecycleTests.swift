import Foundation

// Real queue/sidecar/process work, isolated from owner data and hardware.
@MainActor
enum AppLifecycleTests {
    static func run() async throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("nosy-lifecycle-\(UUID().uuidString)")
        let old = ProcessInfo.processInfo.environment
        for (key, value) in ["NOSY_SUPPORT_DIR": root.appendingPathComponent("support").path,
                             "NOSY_TRANSCRIPTS_DIR": root.appendingPathComponent("transcripts").path,
                             "NOSY_WHISPER_CLI": root.appendingPathComponent("whisper-cli").path] { setenv(key, value, 1) }
        defer {
            for key in ["NOSY_SUPPORT_DIR", "NOSY_TRANSCRIPTS_DIR", "NOSY_WHISPER_CLI"] {
                if let value = old[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? manager.removeItem(at: root)
        }
        var stress: String? = "Mac is hot"
        let model = AppModel(stressReason: { stress })
        model.useTestModelValidation { _ in true }
        let paths = model.paths
        try paths.prepareSupport()
        let cli = root.appendingPathComponent("whisper-cli")
        let gate = root.appendingPathComponent("continue")
        let calls = root.appendingPathComponent("calls")
        func script(_ body: String) throws {
            try Data(("#!/bin/bash\n" + body + "\n").utf8).write(to: cli)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        }
        func waitFor(_ message: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<400 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            expect(false, message)
        }
        func record(_ id: String) throws -> SessionRecord {
            let record = SessionRecord(id: id, lecture: "General", session: id, startedAt: Date(), status: .failed)
            try record.save(in: paths)
            try Data(repeating: 0, count: 32_000).write(to: paths.audioFile(id, "pcm"))
            return record
        }
        try script("""
        base=''
        while [[ $# -gt 0 ]]; do
            case "$1" in -of) base="$2"; shift 2 ;; *) shift ;; esac
        done
        printf '%s\\n' "$base" >> '\(calls.path)'
        while [[ ! -f '\(gate.path)' ]]; do /bin/sleep 0.02; done
        if [[ "$base" == *queue-fail* ]]; then printf 'engine failure\\n' >&2; exit 3; fi
        printf 'Useful words from the lecture.\\n' > "$base.txt"
        """)
        let first = try record("queue-first"), failure = try record("queue-fail"), last = try record("queue-last")
        model.retry(first); model.retry(failure); model.retry(last); model.retry(failure)
        expect(model.active == nil && model.queue.map(\.id) == [first.id, failure.id, last.id], "stress queues all jobs and a duplicate retry adds nothing")
        expect(model.transcriptionPauseReason == "Mac is hot", "thermal pause is visible")
        stress = nil; model.updateStress()
        try await waitFor("first queued process starts") { Core.fileSize(calls) > 0 }
        stress = "battery low"; model.updateStress()
        try Data().write(to: gate)
        try await Task.sleep(for: .milliseconds(200))
        expect(model.active?.id == first.id && model.queue.count == 2 && model.transcriptionPauseReason == "battery low", "battery pause holds an active process and its queue")
        stress = nil; model.updateStress()
        try await waitFor("queue finishes after resume, including after a failure") { model.active == nil && model.queue.isEmpty }
        expect(model.phase == .done && model.current?.id == last.id, "foreground follows the selected job through background completion")
        let storedFailure = try SessionRecord.read(paths.audioFile(failure.id, "json"))
        expect(storedFailure.status == .failed && Core.friendlyError(storedFailure.error ?? "").contains("hit a snag"), "whisper failure persists a usable retry")
        expect(manager.fileExists(atPath: paths.audioFile(failure.id, "wav").path), "failed job keeps its audio")
        try script("""
        base=''
        while [[ $# -gt 0 ]]; do case "$1" in -of) base="$2"; shift 2 ;; *) shift ;; esac; done
        printf 'Retry succeeds.\\n' > "$base.txt"
        """)
        model.retry(storedFailure)
        try await waitFor("failed job can retry successfully") { model.active == nil && model.queue.isEmpty }
        expect(model.phase == .done && model.current?.id == failure.id, "Retry reaches Saved")

        let started = root.appendingPathComponent("quit-started")
        try script("trap '' TERM; touch '\(started.path)'; while :; do /bin/sleep 0.1; done")
        let running = try record("quit-active"), queued = try record("quit-queued")
        model.retry(running); model.retry(queued)
        try await waitFor("quit test process starts") { manager.fileExists(atPath: started.path) }
        await model.prepareToQuit()
        for record in [running, queued] {
            let saved = try SessionRecord.read(paths.audioFile(record.id, "json"))
            expect(saved.status == .failed && saved.error == "Quit before transcription", "quit settles active and queued sidecars")
            expect(manager.fileExists(atPath: paths.audioFile(record.id, "wav").path), "quit finalizes both recordings without losing audio")
        }
        expect(!model.working, "quit releases queue activity")

        let suite = "com.bardya.nosy.lifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AIFeatures.storageKey)
        defaults.set(SummaryProvider.claudeCode.rawValue, forKey: SummarySettings.providerKey)
        let center = SummaryCenter()
        center.defaults = defaults
        center.waitReason = { _ in "Test pause" }
        let transcript = URL(fileURLWithPath: model.current?.transcriptPath ?? root.appendingPathComponent("transcript.md").path)
        let document = "# General\n\n- Date: 2026-10-24\n- Length: 1 min\n\n## Transcript\n\nWords to summarize.\n"
        try Data(document.utf8).write(to: transcript)
        center.configurePreview(detection: SummaryDetection(executables: [.claudeCode: cli], checked: true))
        center.summarize(transcript)
        let second = root.appendingPathComponent("second.md")
        try Data(document.utf8).write(to: second)
        center.summarize(second)
        await Task.yield()
        expect(center.hasPendingWork && center.status.count == 2, "summary has active and queued work")
        await center.shutdown()
        expect(!center.hasPendingWork && center.status.isEmpty, "summary shutdown settles waiting and queued statuses")

        let importer = AppModel(stressReason: { nil })
        let source = root.appendingPathComponent("Quit import.wav")
        let pcm = Data(repeating: 0, count: 3_200_000)
        try (Core.wavHeader(pcmBytes: Int64(pcm.count)) + pcm).write(to: source)
        let sourceData = try Data(contentsOf: source)
        importer.importRecordings([source, source], targetLecture: "Imported")
        await Task.yield()
        await importer.prepareToQuit()
        expect(importer.importsInProgress == 0 && importer.active == nil && importer.queue.isEmpty && !importer.transitioning,
               "quit waits for an in-flight import and starts no later job")
        let sourceAfterQuit = try Data(contentsOf: source)
        expect(sourceAfterQuit == sourceData, "quit never changes the imported source")
        let imported = Core.records(in: paths).filter { $0.lecture == "Imported" }
        expect(imported.count <= 1 && imported.allSatisfy { $0.status == .failed }, "interrupted imports retain a recoverable sidecar")
        print("APP LIFECYCLE PASS: queue, duplicate retry, thermal and battery pause/resume, failure/Retry, quit, summaries and import")
    }
}
