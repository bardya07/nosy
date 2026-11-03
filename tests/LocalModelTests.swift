import Foundation

@main
@MainActor
enum LocalModelTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw LectureError.message(message) }
    }
    static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else { throw LectureError.message("Timed out: \(message)") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    static func main() async {
        do {
            if CommandLine.arguments.contains("--real") { try await real(); return }
            try catalog()
            try await downloads()
            try await runner()
            print("LOCAL MODEL TESTS PASS: defaults, groups, RAM recommendation, progress, cancel, resume, Range fallback, checksum, receipt, removal, arguments, map cache, bounded reduce, runner cancellation, recording suspension")
        } catch {
            FileHandle.standardError.write(Data("LOCAL MODEL TEST FAILED: \(error)\n".utf8)); exit(1)
        }
    }
    static func catalog() throws {
        try check(SummarySettings().provider == .off && !SummarySettings().automatic, "Optional and off by default")
        try check(LocalModel.recommended(memory: 8 * 1024 * 1024 * 1024) == .smol, "8 GB recommendation")
        try check(LocalModel.recommended(memory: 16 * 1024 * 1024 * 1024) == .qwen, "16 GB recommendation")
        try check(SummaryProvider.menuGroups.map(\.title) == ["Built in (on this Mac)", "Your AI apps", "Local apps", "API keys"], "Menu group names")
        try check(SummaryProvider.menuGroups.flatMap(\.providers) == SummaryProvider.allCases.filter { $0 != .off }, "Every provider grouped once")
        try check(SummaryProvider.qwen.staysOnMac && SummaryDetection().isAvailable(.smol), "Built in providers always selectable")
        try check(LocalModel.all.allSatisfy { $0.url.path.contains($0.revision) && $0.sha256.count == 64 }, "Immutable model URLs and hashes")
        let chunks = LlamaRunner.chunks("## Transcript\n\n" + String(repeating: "[01:02] ATP supplies energy.\n", count: 1000))
        try check(chunks.count > 1 && chunks.allSatisfy { $0.utf8.count <= 9600 }, "Bounded chunks")
        try check(chunks.allSatisfy { $0.contains("[01:02]") }, "Source timestamps preserved")
        try check(LlamaRunner.mapPrompt("no timestamp", terms: "").contains("Never invent a timestamp"), "No fabricated times")
        let checked = LlamaRunner.checkedOutput("## Key terms\n- Zebra: last [99:59]\n- Apple: first", section: .terms, source: "[00:05] source")
        try check(!checked.contains("99:59") && checked.contains("Apple: first [time not stated]") && checked.range(of: "Apple")!.lowerBound < checked.range(of: "Zebra")!.lowerBound, "Missing and fabricated timestamps labeled; terms sorted")
        let args = LlamaRunner.arguments(model: "/tmp/model with spaces.gguf", promptFile: URL(fileURLWithPath: "/tmp/private prompt"), tokens: 250)
        try check(args == ["--model", "/tmp/model with spaces.gguf", "--prompt-file", "/tmp/private prompt", "--ctx", "8192", "--predict", "250"], "One shot runner arguments")
    }
    static func downloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nosy-local-model-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["tests/LocalModelServer.py", root.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        try await eventually("fake server") { FileManager.default.fileExists(atPath: root.appendingPathComponent("port").path) }
        let port = try String(contentsOf: root.appendingPathComponent("port"), encoding: .utf8)
        let source = URL(string: "http://127.0.0.1:\(port)/model")!
        let payload = root.appendingPathComponent("payload")
        let model = LocalModel(id: "fixture", name: "Fixture", fileName: "fixture.gguf", repository: "test", revision: "test",
                               bytes: Core.fileSize(payload), sha256: try LocalModelDownload.sha256(payload))
        let store = LocalModelStore(root: root.appendingPathComponent("models"))
        store.download(model, source: source)
        try await eventually("download progress") {
            if case .downloading(let bytes) = store.state(model) { return bytes > 0 && bytes < model.bytes }; return false
        }
        store.cancel(model)
        try await eventually("cancel settles") { !store.hasDownloads }
        let retained = Core.fileSize(store.partial(model))
        try check(retained > 0 && retained < model.bytes, "Cancelled download retains partial bytes")
        try check(!store.available(model), "Partial model never available")
        store.download(model, source: source)
        try await eventually("resume") { !store.hasDownloads }
        try check(store.state(model) == .downloaded && store.available(model), "Resumed model verified and installed")
        let audit = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        try check(audit.contains("bytes=\(retained)-"), "Resume sends HTTP Range")
        store.setLoaded(model, true)
        try store.remove(model)
        try check(store.available(model), "Cannot remove a loaded model")
        store.setLoaded(model, false)
        try store.remove(model)
        try check(!store.available(model) && !FileManager.default.fileExists(atPath: store.file(model).path), "Removal deletes model and receipt")
        // A server that ignores Range must restart cleanly, never append a full body to a partial.
        try Data(contentsOf: payload).prefix(8192).write(to: store.partial(model))
        store.download(model, source: URL(string: "http://127.0.0.1:\(port)/ignore")!)
        try await eventually("Range ignored") { !store.hasDownloads }
        try check(store.available(model), "Ignored Range safely restarts")
        try store.remove(model)
        // Local file URLs exercise the same transfer and checksum path without a server.
        store.download(model, source: payload)
        try await eventually("file URL") { !store.hasDownloads }
        try check(store.available(model), "File URL is verified")
        try Data([0]).write(to: store.file(model))
        try check(!store.available(model), "Changed file invalidates receipt")
        try store.remove(model)
        let bad = LocalModel(id: model.id, name: model.name, fileName: model.fileName, repository: model.repository,
                             revision: model.revision, bytes: model.bytes, sha256: String(repeating: "0", count: 64))
        store.download(bad, source: payload)
        try await eventually("bad checksum") { !store.hasDownloads }
        if case .error(let message) = store.state(bad) { try check(message.contains("SHA256"), "Clear checksum failure") }
        else { throw LectureError.message("Bad checksum did not fail") }
        try check(!store.available(bad) && Core.fileSize(store.partial(bad)) == 0, "Corrupt partial removed")
        store.download(model, source: source)
        try await eventually("shutdown progress") { Core.fileSize(store.partial(model)) > 0 }
        await store.shutdown()
        try check(!store.hasDownloads && !store.available(model), "Quit cancels and settles downloads")
    }
    static func runner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nosy-llama-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("fake-helper")
        let calls = root.appendingPathComponent("calls")
        let fake = """
        #!/bin/sh
        echo called >> '\(calls.path)'
        printf '## Short notes\\n• ATP supplies energy [01:02].\\n'
        """
        try fake.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        var settings = SummarySettings(); settings.provider = .qwen
        let request = SummaryRequest(provider: .qwen, model: "/fake/model", executable: helper)
        settings.sections = [.notes]
        let transcript = "## Transcript\n[01:02] ATP supplies energy."
        _ = try await Summarizer.summarize(transcript, settings: settings, request: request, job: TranscriptionJob(), cacheRoot: root)
        settings.sections = [.questions]
        _ = try await Summarizer.summarize(transcript, settings: settings, request: request, job: TranscriptionJob(), cacheRoot: root)
        let count = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count
        try check(count == 4, "Changing sections maps again without persistent notes")
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("notes").path), "No persistent notes are written")
        // Force a hierarchical reduce with many bounded map outputs.
        let verbose = "#!/bin/sh\necho called >> '\(calls.path)'\nprintf '" + String(repeating: "source note ", count: 160) + "'\n"
        try verbose.write(to: helper, atomically: true, encoding: .utf8)
        try Data().write(to: calls)
        let longTranscript = "## Transcript\n" + String(repeating: "[01:02] ATP supplies energy.\n", count: 2300)
        let partCount = LlamaRunner.chunks(longTranscript).count
        _ = try await Summarizer.summarize(longTranscript, settings: settings, request: request, job: TranscriptionJob())
        let reducedCalls = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count
        try check(reducedCalls > partCount + 1, "Long notes use bounded intermediate reduce groups")
        // A fake real tokenizer limit proves dense excerpts retry with smaller chunks.
        let limited = """
        #!/bin/sh
        echo called >> '\(calls.path)'
        if [ "$(wc -c < "$4")" -gt 7000 ]; then exit 3; fi
        printf '## Short notes\\n• ATP supplies energy [01:02].\\n'
        """
        try limited.write(to: helper, atomically: true, encoding: .utf8)
        try Data().write(to: calls)
        let dense = "## Transcript\n" + String(repeating: "Dense text. ", count: 700)
        _ = try await Summarizer.summarize(dense, settings: settings, request: request, job: TranscriptionJob())
        let splitCalls = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count
        try check(splitCalls >= 4, "Context overflow splits the source and retries")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: helper, atomically: true, encoding: .utf8)
        let pause = LlamaPauseState(); pause.set(true)
        let started = root.appendingPathComponent("started")
        var pausedRequest = request; pausedRequest.timeout = 0.4; pausedRequest.pauseState = pause
        try "#!/bin/sh\ntouch '\(started.path)'\n/bin/sleep 0.8\nprintf 'A complete supported answer.'\n".write(to: helper, atomically: true, encoding: .utf8)
        let pausedTask = Task { try await SummaryRunner.run("test", request: pausedRequest, job: TranscriptionJob()) }
        try await eventually("paused helper launch") { FileManager.default.fileExists(atPath: started.path) }
        try await Task.sleep(for: .milliseconds(650)); pause.set(false)
        _ = try await pausedTask.value
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: helper, atomically: true, encoding: .utf8)
        var shortRequest = request; shortRequest.timeout = 0.1
        do {
            _ = try await SummaryRunner.run("test", request: shortRequest, job: TranscriptionJob())
            throw LectureError.message("Active helper did not time out")
        } catch SummaryError.timedOut {}
        let job = TranscriptionJob()
        let task = Task { try await SummaryRunner.run("test", request: request, job: job) }
        try await Task.sleep(for: .milliseconds(200))
        job.suspend() // Quit also terminates a stopped helper.
        task.cancel()
        let start = Date()
        do { _ = try await task.value; throw LectureError.message("Cancellation unexpectedly succeeded") }
        catch is CancellationError {}
        try check(Date().timeIntervalSince(start) < 4, "Cancellation reaps the suspended child promptly")
        // The live guard receives Published changes synchronously before recording begins.
        let guardJob = TranscriptionJob()
        let activity = SummaryCenter.observeLocalActivity(model: AppModel.shared, job: guardJob)
        AppModel.shared.phase = .recording
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["30"]
        try guardJob.launch(process)
        try await Task.sleep(for: .milliseconds(100))
        let probe = Process(); probe.executableURL = URL(fileURLWithPath: "/bin/ps")
        probe.arguments = ["-o", "state=", "-p", String(process.processIdentifier)]
        let pipe = Pipe(); probe.standardOutput = pipe
        try probe.run(); probe.waitUntilExit()
        let processState = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try check(processState.contains("T"), "Recording stops the helper before it can use CPU or GPU")
        guardJob.cancel(); process.waitUntilExit(); activity.cancel(); AppModel.shared.phase = .idle
    }
    static func real() async throws {
        let store = LocalModelStore()
        if !store.available(.qwen) {
            store.download(.qwen)
            while store.hasDownloads {
                if case .downloading(let bytes) = store.state(.qwen) { print("QWEN DOWNLOAD: \(bytes / 1_000_000) MB") }
                try await Task.sleep(for: .seconds(5))
            }
        }
        try check(store.available(.qwen), "Real model download verified")
        let transcript = """
        # Biology review
        ## Transcript
        [00:05] Today we will cover enzymes. An enzyme speeds up a chemical reaction by lowering its activation energy. It is not consumed in the reaction and does not change the reaction's equilibrium.
        [00:25] A substrate binds at the enzyme's active site. A competitive inhibitor competes with the substrate for the active site. Increasing substrate concentration can overcome competitive inhibition.
        [00:50] Feedback inhibition happens when the final product of a pathway inhibits an earlier enzyme. This prevents a cell from making more product than it needs.
        [01:10] For the exam, explain the difference between competitive inhibition and feedback inhibition. We have not discussed noncompetitive inhibition today.
        """
        var settings = SummarySettings(); settings.provider = .qwen; settings.sections = SummarySection.allCases
        let helper = URL(fileURLWithPath: CommandLine.arguments.last!)
        let request = SummaryRequest(provider: .qwen, model: store.file(.qwen).path, executable: helper)
        let start = Date()
        let summary = try await Summarizer.summarize(transcript, settings: settings, request: request, job: TranscriptionJob(), cacheRoot: store.root)
        let elapsed = Date().timeIntervalSince(start)
        try check(summary.contains("## Short notes") && summary.lowercased().contains("enzyme"), "Real summary has meaningful content and sections")
        let fixture = URL(fileURLWithPath: "vendor/real-fixture.md")
        try transcript.write(to: fixture, atomically: true, encoding: .utf8)
        try SummaryFiles.save(SummaryFiles.document(body: summary, transcript: fixture, provider: .qwen), for: fixture, expectedText: transcript)
        print("REAL SUMMARY: \(String(format: "%.2f", elapsed)) seconds\n\(summary)")
        try summary.write(to: URL(fileURLWithPath: "vendor/real-summary.md"), atomically: true, encoding: .utf8)
    }
}
