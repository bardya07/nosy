import Foundation

// Summaries: prompt building, CLI detection and runs with fake binaries, the Keychain wrapper,
// summary file naming, HTTP request shapes, and chunking.
@main
enum SummaryTests {
    static func main() async {
        do {
            try await run()
            print("SUMMARY TESTS PASS: prompt, detection, fake CLI runs, keychain, file naming, http shapes, chunking")
        } catch {
            FileHandle.standardError.write(Data("SUMMARY TEST FAILED: \(error)\n".utf8))
            exit(1)
        }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("SUMMARY TEST FAILED: \(message)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        try prompts()
        try chunking()
        try files()
        try keychain()
        try http()
        try await cli()
    }

    static func prompts() throws {
        let prompt = SummaryPrompt.build(transcript: "  ATP drives work.  ", sections: [.questions, .notes], custom: " Use British spelling. ")
        let notes = prompt.range(of: "## Short notes"), questions = prompt.range(of: "## Likely exam questions")
        check(notes != nil && questions != nil, "chosen sections appear")
        check(notes!.lowerBound < questions!.lowerBound, "sections keep the fixed order, not the selection order")
        check(!prompt.contains("## Key terms"), "an unchosen section is left out")
        check(prompt.contains("Additional instructions from the student:\nUse British spelling."), "custom instructions are trimmed and included")
        check(prompt.contains("<transcript>\nATP drives work.\n</transcript>"), "the transcript is wrapped and trimmed")
        check(!prompt.contains("part 1 of"), "a whole transcript has no part header")
        check(!SummaryPrompt.build(transcript: "x", sections: [.notes], custom: "   ").contains("Additional instructions"),
              "blank custom instructions add nothing")
        check(SummaryPrompt.build(transcript: "x", sections: [], custom: "").contains("## Short notes"), "no sections falls back to notes")
        let part = SummaryPrompt.build(transcript: "x", sections: [.terms], custom: "", part: (2, 3))
        check(part.contains("This is part 2 of 3"), "parts say which part they are")
        let merge = SummaryPrompt.merge(partials: ["## Key terms\n- a", "## Key terms\n- b"], sections: [.terms], custom: "Be brief.")
        check(merge.contains("<part number=\"1\">") && merge.contains("<part number=\"2\">") && merge.contains("Be brief."), "merge carries every part and the instructions")
        // Settings load from defaults with sensible fallbacks.
        let suite = "com.bardya.nosy.summary-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = SummarySettings.load(defaults)
        check(settings.provider == .off && !settings.automatic && settings.sections == [.notes, .terms], "defaults: off, manual, notes and terms")
        defaults.set("anthropic", forKey: SummarySettings.providerKey)
        defaults.set(true, forKey: SummarySection.questions.storageKey)
        defaults.set(false, forKey: SummarySection.notes.storageKey)
        settings = SummarySettings.load(defaults)
        check(settings.provider == .anthropic && settings.model == "claude-haiku-5-5", "an API provider defaults to its small model")
        check(settings.sections == [.terms, .questions], "section toggles load")
        defaults.set(" my-model ", forKey: SummaryProvider.anthropic.modelKey)
        check(SummarySettings.load(defaults).model == "my-model", "an edited model is trimmed")
    }

    static func chunking() throws {
        check(SummaryChunker.chunks("short", limit: 100) == ["short"], "short text is one chunk")
        let paragraphs = (1...40).map { "Paragraph \($0) talks about enzymes. It has two sentences." }
        let text = paragraphs.joined(separator: "\n\n")
        let chunks = SummaryChunker.chunks(text, limit: 300)
        check(chunks.count > 1, "long text splits")
        check(chunks.allSatisfy { $0.count <= 300 }, "every chunk fits the limit")
        check(chunks.joined(separator: "\n\n") == text, "paragraph splits lose nothing")
        let long = String(repeating: "word ", count: 200) + "Done."
        let words = SummaryChunker.chunks(long, limit: 50)
        check(words.allSatisfy { $0.count <= 50 }, "a long paragraph splits at words")
        check(words.joined(separator: " ").split(separator: " ").count == long.split(separator: " ").count, "word splits keep every word")
        let giant = String(repeating: "x", count: 130)
        let pieces = SummaryChunker.chunks(giant, limit: 50)
        check(pieces.count == 3 && pieces.joined() == giant, "an unbreakable word is cut hard")
    }

    static func files() throws {
        let transcript = URL(fileURLWithPath: "/tmp/Nosy/MBB322/2026-10-23.md")
        check(SummaryFiles.url(for: transcript).path == "/tmp/Nosy/MBB322/2026-10-23 summary.md", "summary sits next to the transcript")
        check(SummaryFiles.isSummary(URL(fileURLWithPath: "/x/Week 1 summary.md"), siblings: ["Week 1.md", "Week 1 summary.md"]),
              "a summary beside its transcript is recognised")
        check(!SummaryFiles.isSummary(URL(fileURLWithPath: "/x/Week 1 summary.md"), siblings: ["Week 1 summary.md"]),
              "a session named like a summary stays a transcript")
        check(!SummaryFiles.isSummary(URL(fileURLWithPath: "/x/ summary.md"), siblings: [".md", " summary.md"]), "a bare suffix is not a summary")
        let document = SummaryFiles.document(body: "\n## Short notes\n- a\n", transcript: transcript, provider: .ollama,
                                             date: Date(timeIntervalSince1970: 1_793_000_000))
        check(document.hasPrefix("# 2026-10-23 summary\n\n_Summarized with Ollama on "), "document has a title and provenance")
        check(document.hasSuffix("## Short notes\n- a\n"), "document keeps the body")
        check(SummaryFiles.clean("```markdown\n## Key terms\n- a\n```") == "## Key terms\n- a", "code fences are removed")
        check(SummaryFiles.clean("  ## Notes  ") == "## Notes", "replies are trimmed")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nosy-summary-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("Week.md")
        let second = SummaryFiles.url(for: first)
        let text = "# Course\n\n- Date: 2026-10-23\n- Length: 1 min\n\n## Transcript\n\nSpeech.\n"
        try Data(text.utf8).write(to: first)
        try Data(text.utf8).write(to: second)
        check(!SummaryFiles.isSummary(second, siblings: ["Week.md", "Week summary.md"]), "a real transcript ending in summary stays visible")
        check(SummaryFiles.existing(for: first) == nil, "another transcript is never read as a summary")
        var refused = false
        do { try SummaryFiles.save(document, for: first, expectedText: text) } catch { refused = true }
        let preserved = try String(contentsOf: second, encoding: .utf8)
        check(refused && preserved == text, "summarizing cannot overwrite a transcript")
        try FileManager.default.removeItem(at: second)
        try Data("Owner note".utf8).write(to: second)
        refused = false
        do { try SummaryFiles.save(document, for: first, expectedText: text) } catch { refused = true }
        check(refused && SummaryFiles.existing(for: first) == nil, "an unrelated note is neither overwritten nor treated as a summary")
        try FileManager.default.removeItem(at: second)
        try SummaryFiles.save(document, for: first, expectedText: text)
        check(SummaryFiles.existing(for: first) == second, "a generated summary is recognised")
        try Data((text + "Edited").utf8).write(to: first)
        refused = false
        do { try SummaryFiles.save("Replacement", for: first, expectedText: text) } catch { refused = true }
        check(refused, "a stale summary cannot replace one after an edit")
    }

    static func keychain() throws {
        let store = SummaryKeychain(service: "com.bardya.nosy.summaries.tests.\(UUID().uuidString)")
        defer { try? store.delete(account: "anthropic"); try? store.delete(account: "openAI") }
        func read(account: String) -> String? {
            do { return try store.read(account: account) } catch { fatalError("Unexpected Keychain failure: \(error)") }
        }
        check(read(account: "anthropic") == nil, "nothing is stored at first")
        try store.save(" sk-test-1234567890 ", account: "anthropic")
        check(read(account: "anthropic") == "sk-test-1234567890", "a saved key reads back trimmed")
        try store.save("sk-test-replaced-abcd", account: "anthropic")
        check(read(account: "anthropic") == "sk-test-replaced-abcd", "saving again replaces the key")
        check(read(account: "openAI") == nil, "accounts are separate")
        try store.delete(account: "anthropic")
        check(read(account: "anthropic") == nil, "remove deletes the key")
        try store.delete(account: "anthropic")
        var threw = false
        do { try store.save("   ", account: "openAI") } catch { threw = true }
        check(threw && read(account: "openAI") == nil, "an empty key is refused")
        check(SummaryKeychain.masked("sk-test-replaced-abcd") == "••••••••abcd", "masking shows only the last four")
        check(SummaryKeychain.masked("short") == "••••••••", "short keys show nothing")
    }

    static func http() throws {
        let anthropic = try SummaryRunner.httpRequest("hello", request: SummaryRequest(provider: .anthropic, model: "claude-haiku-5-5", apiKey: "k1"))
        check(anthropic.url?.absoluteString == "https://api.anthropic.com/v1/messages", "anthropic endpoint")
        check(anthropic.value(forHTTPHeaderField: "x-api-key") == "k1" && anthropic.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21",
              "anthropic headers")
        let body = try JSONSerialization.jsonObject(with: anthropic.httpBody!) as! [String: Any]
        check(body["model"] as? String == "claude-haiku-5-5" && body["temperature"] == nil, "anthropic body")
        let openAI = try SummaryRunner.httpRequest("hello", request: SummaryRequest(provider: .openAI, model: "gpt-5-mini", apiKey: "k2"))
        check(openAI.value(forHTTPHeaderField: "Authorization") == "Bearer k2", "openai bearer key")
        let gemini = try SummaryRunner.httpRequest("hello", request: SummaryRequest(provider: .gemini, model: "gemini-2.5-flash", apiKey: "k3"))
        check(gemini.url?.absoluteString.hasSuffix("/models/gemini-2.5-flash:generateContent") == true
              && gemini.value(forHTTPHeaderField: "x-goog-api-key") == "k3" && gemini.url?.query == nil, "gemini key in a header, not the URL")
        let oddModel = try SummaryRunner.httpRequest("x", request: SummaryRequest(provider: .gemini, model: "m?#/%", apiKey: "secret"))
        check(oddModel.url?.query == nil && oddModel.url?.fragment == nil, "an edited model cannot inject URL delimiters")
        check(SummaryRunner.redacted("Invalid key secret", key: "secret") == "Invalid key [key removed]", "provider errors cannot echo the API key")
        let ollama = try SummaryRunner.httpRequest("hello", request: SummaryRequest(provider: .ollama, model: "qwen3:8b"))
        check(ollama.url?.absoluteString == "http://localhost:11434/api/chat", "ollama native chat endpoint")
        let lm = try SummaryRunner.httpRequest("hello", request: SummaryRequest(provider: .lmStudio, model: "local"))
        check(lm.url?.absoluteString == "http://localhost:1234/v1/chat/completions", "lm studio openai compatible endpoint")
        var error: SummaryError?
        do { _ = try SummaryRunner.httpRequest("x", request: SummaryRequest(provider: .openAI, model: "m")) } catch let e as SummaryError { error = e }
        check(error == .noKey("OpenAI API key"), "an API provider without a key says so")
        error = nil
        do { _ = try SummaryRunner.httpRequest("x", request: SummaryRequest(provider: .ollama, model: " ")) } catch let e as SummaryError { error = e }
        check(error == .noModel, "a local provider needs a model")

        func data(_ json: String) -> Data { Data(json.utf8) }
        check(SummaryRunner.parseReply(data(#"{"message":{"content":"A"}}"#), provider: .ollama) == "A", "ollama reply")
        check(SummaryRunner.parseReply(data(#"{"choices":[{"message":{"content":"B"}}]}"#), provider: .openAI) == "B", "openai reply")
        check(SummaryRunner.parseReply(data(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"C"}]}"#), provider: .anthropic) == "C",
              "anthropic reply skips thinking blocks")
        check(SummaryRunner.parseReply(data(#"{"candidates":[{"content":{"parts":[{"text":"D"},{"text":"E"}]}}]}"#), provider: .gemini) == "DE", "gemini reply")
        let complete: [(SummaryProvider, String)] = [
            (.ollama, #"{"done":true,"done_reason":"stop"}"#),
            (.openAI, #"{"choices":[{"finish_reason":"stop"}]}"#),
            (.anthropic, #"{"stop_reason":"end_turn"}"#),
            (.gemini, #"{"candidates":[{"finishReason":"STOP"}]}"#),
        ]
        for (provider, response) in complete {
            try SummaryRunner.checkCompletion(data(response), provider: provider)
            var rejected = false
            do { try SummaryRunner.checkCompletion(data("{}"), provider: provider) } catch { rejected = true }
            check(rejected, "missing completion reason rejected for \(provider.title)")
        }
        do {
            try SummaryRunner.checkCompletion(data(#"{"choices":[{"finish_reason":"length"}]}"#), provider: .openAI)
            check(false, "truncated output must fail")
        } catch SummaryError.truncated { }
        check(SummaryRunner.parseError(data(#"{"error":{"message":"bad key"}}"#)) == "bad key", "error messages are read")
        check(SummaryDetector.parseOllamaModels(data(#"{"models":[{"name":"b"},{"name":"a"}]}"#)) == ["a", "b"], "ollama model list")
        check(SummaryDetector.parseOpenAIModels(data(#"{"data":[{"id":"m1"}]}"#)) == ["m1"], "lm studio model list")
        check(SummaryError.short(String(repeating: "x", count: 300)).count == 120, "long errors are shortened")
        check(SummaryError.short("\n\n  first line\nsecond") == "first line", "errors keep their first line")
    }

    static func cli() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("nosy-summary-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin"), other = root.appendingPathComponent("other"), home = root.appendingPathComponent("home")
        for folder in [bin, other, home.appendingPathComponent(".nvm/versions/node/v20.1.0/bin"), home.appendingPathComponent(".nvm/versions/node/v22.3.0/bin")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        func script(_ url: URL, _ body: String, executable: Bool = true) throws {
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
        // A fake Claude Code: prints its arguments' count, then echoes the prompt it got on stdin as a summary.
        try script(bin.appendingPathComponent("claude"), """
        input=$(cat)
        echo "$*" >> "\(root.path)/calls.txt"
        case "$input" in *"part 2 of"*) echo "## Short notes"; echo "- second";; *"<part number"*) echo "## Short notes"; echo "- merged";; *) echo "## Short notes"; echo "- first";; esac
        """)
        try script(other.appendingPathComponent("codex"), "exit 0", executable: false)
        try script(other.appendingPathComponent("gemini"), "echo 'quota exceeded' >&2; exit 3")
        try FileManager.default.createDirectory(at: other.appendingPathComponent("codex-dir"), withIntermediateDirectories: true)

        let directories = SummaryDetector.searchDirectories(home: home, loginPath: "\(bin.path):\(other.path):\(bin.path)")
        let paths = directories.map(\.path)
        check(paths.contains("/opt/homebrew/bin") && paths.contains(home.appendingPathComponent(".local/bin").path)
              && paths.contains(home.appendingPathComponent(".npm-global/bin").path), "common install folders are searched")
        check(paths.filter { $0 == bin.path }.count == 1, "search folders are not repeated")
        let v22 = paths.firstIndex(of: home.appendingPathComponent(".nvm/versions/node/v22.3.0/bin").path)
        let v20 = paths.firstIndex(of: home.appendingPathComponent(".nvm/versions/node/v20.1.0/bin").path)
        check(v22 != nil && v20 != nil && v22! < v20!, "newest nvm node comes first")
        let fakes = [bin, other]
        check(SummaryDetector.findExecutable("claude", in: fakes)?.path == bin.appendingPathComponent("claude").path, "an executable is found")
        check(SummaryDetector.findExecutable("codex", in: fakes) == nil, "a file that isn't executable is ignored")
        check(SummaryDetector.findExecutable("codex-dir", in: fakes) == nil, "a folder is ignored")
        let found = SummaryDetector.detectExecutables(in: fakes)
        check(found[.claudeCode] != nil && found[.geminiCLI] != nil && found[.codex] == nil, "detection maps CLIs to providers")
        var detection = SummaryDetection(executables: found, localModels: [.ollama: []], checked: true)
        check(!detection.isAvailable(.claudeCode) && !detection.isAvailable(.codex), "CLIs remain unavailable even when installed")
        check(detection.isAvailable(.ollama) && !detection.isAvailable(.lmStudio), "a running server is available even with no models")
        check(detection.isAvailable(.anthropic) && detection.isAvailable(.off), "API providers are always available")
        detection.localModels[.ollama] = nil
        check(!detection.isAvailable(.ollama), "a stopped server is unavailable")

        // CLI arguments: prompts go through stdin; codex stays read only.
        let last = URL(fileURLWithPath: "/tmp/last.txt")
        check(SummaryRunner.cliArguments(.claudeCode, model: "", lastMessage: last) == ["-p", "--output-format", "text"], "claude args")
        let codex = SummaryRunner.cliArguments(.codex, model: "gpt-5-codex", lastMessage: last)
        check(codex.starts(with: ["exec", "--sandbox", "read-only"]) && codex.last == "-" && codex.contains("--output-last-message"), "codex args")
        check(SummaryRunner.cliArguments(.geminiCLI, model: "m", lastMessage: last).suffix(2) == ["--model", "m"], "gemini args carry the model")

        // A configured executable must never receive transcript text.
        for provider in [SummaryProvider.claudeCode, .codex, .geminiCLI] {
            var failure: SummaryError?
            do {
                _ = try await SummaryRunner.run("private text", request: SummaryRequest(provider: provider, model: "", executable: found[provider]), job: TranscriptionJob())
            } catch let error as SummaryError { failure = error }
            check(failure == .failed(provider.title, "This CLI cannot be verified as a text-only completion. Choose a built-in model or an API provider instead."), "CLI refused before execution")
        }
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("calls.txt").path), "CLI was not executed")
    }
}
