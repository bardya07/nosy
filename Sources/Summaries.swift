import Foundation
import Security
import Combine

// Summaries: one prompt built from the chosen sections, run by a provider the student picks
// (a CLI they already use, a local server, or their own API key). Nothing here blocks
// transcription; every failure becomes a short message.

enum SummarySection: String, CaseIterable, Sendable, Identifiable {
    case notes, terms, questions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .notes: "Short notes"
        case .terms: "Key terms with definitions"
        case .questions: "Likely exam questions"
        }
    }
    var heading: String {
        switch self {
        case .notes: "Short notes"
        case .terms: "Key terms"
        case .questions: "Likely exam questions"
        }
    }
    var instruction: String {
        switch self {
        case .notes: "A concise outline of the main ideas as bullet points, in the order the lecture covers them."
        case .terms: "Each important term as a bullet point in the form \"- **Term**: one sentence definition\", using the meaning from this lecture."
        case .questions: "Five to ten questions a professor could plausibly ask about this lecture on an exam, as a numbered list."
        }
    }
    var storageKey: String { "summaries.include.\(rawValue)" }
    var includedByDefault: Bool { self != .questions }
}

enum SummaryProvider: String, CaseIterable, Sendable, Identifiable {
    case off, qwen, smol, claudeCode, codex, geminiCLI, ollama, lmStudio, openAI, anthropic, gemini
    var id: String { rawValue }

    enum Kind: Equatable, Sendable { case none, builtIn, cli(String), local, api }
    var kind: Kind {
        switch self {
        case .off: .none
        case .qwen, .smol: .builtIn
        case .claudeCode: .cli("claude")
        case .codex: .cli("codex")
        case .geminiCLI: .cli("gemini")
        case .ollama, .lmStudio: .local
        case .openAI, .anthropic, .gemini: .api
        }
    }
    var title: String {
        switch self {
        case .off: "Off"
        case .qwen: "Qwen3 4B"
        case .smol: "SmolLM3 3B"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .geminiCLI: "Gemini CLI"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .openAI: "OpenAI API key"
        case .anthropic: "Anthropic API key"
        case .gemini: "Gemini API key"
        }
    }
    // Shown greyed next to a provider Nosy can't use yet.
    var unavailableHint: String {
        switch self {
        case .claudeCode, .codex, .geminiCLI: "Coming back in an update"
        case .ollama: "Open Ollama to use it"
        case .lmStudio: "Start the LM Studio server to use it"
        default: ""
        }
    }
    // The latest small, inexpensive model of each API; editable in Settings.
    var defaultModel: String {
        switch self {
        case .openAI: "gpt-5-mini"
        case .anthropic: "claude-haiku-5-5"
        case .gemini: "gemini-2.5-flash"
        default: ""
        }
    }
    // Only the bundled helper guarantees local inference.
    var staysOnMac: Bool { self == .off || builtInModel != nil }
    var builtInModel: LocalModel? { self == .qwen ? .qwen : self == .smol ? .smol : nil }
    static let menuGroups: [(title: String, providers: [SummaryProvider])] = [
        ("Built in (on this Mac)", [.qwen, .smol]),
        ("Your AI apps", [.claudeCode, .codex, .geminiCLI]),
        ("Local apps", [.ollama, .lmStudio]),
        ("API keys", [.openAI, .anthropic, .gemini])
    ]
    var localBase: URL? {
        switch self {
        case .ollama: URL(string: "http://localhost:11434")
        case .lmStudio: URL(string: "http://localhost:1234")
        default: nil
        }
    }
    // Characters of transcript per request that fit comfortably in the provider's context.
    var chunkLimit: Int {
        switch self {
        case .off: 0
        case .qwen, .smol: 9_600
        case .ollama: 40_000
        case .lmStudio: 12_000
        case .claudeCode, .codex, .openAI, .anthropic: 400_000
        case .geminiCLI, .gemini: 800_000
        }
    }
    var modelKey: String { "summaries.model.\(rawValue)" }
}

struct SummarySettings: Equatable, Sendable {
    static let providerKey = "summaries.provider"
    static let customKey = "summaries.custom"
    static let automaticKey = "summaries.automatic"

    var provider: SummaryProvider = .off
    var sections: [SummarySection] = SummarySection.allCases.filter(\.includedByDefault)
    var custom = ""
    var automatic = false
    var model = ""

    static func load(_ defaults: UserDefaults = .standard) -> SummarySettings {
        var settings = SummarySettings()
        settings.provider = defaults.string(forKey: providerKey).flatMap(SummaryProvider.init(rawValue:)) ?? .off
        settings.sections = SummarySection.allCases.filter { defaults.object(forKey: $0.storageKey) as? Bool ?? $0.includedByDefault }
        settings.custom = defaults.string(forKey: customKey) ?? ""
        settings.automatic = defaults.bool(forKey: automaticKey)
        settings.model = (defaults.string(forKey: settings.provider.modelKey) ?? settings.provider.defaultModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return settings
    }
}

// MARK: Prompt

enum SummaryPrompt {
    static func sectionSpec(_ sections: [SummarySection], custom: String) -> String {
        let chosen = sections.isEmpty ? [.notes] : SummarySection.allCases.filter(sections.contains)
        var text = "Write Markdown with exactly these sections, in this order, each starting with its \"## \" heading:\n\n"
        text += chosen.map { "## \($0.heading)\n\($0.instruction)" }.joined(separator: "\n\n")
        let extra = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { text += "\n\nAdditional instructions from the student:\n\(extra)" }
        text += "\n\nWrite only the summary: no title, preamble or closing remarks. Use only what the lecture supports."
        return text
    }

    static func build(transcript: String, sections: [SummarySection], custom: String, part: (index: Int, count: Int)? = nil) -> String {
        var text = "You are helping a student review a lecture. Below is an automatic transcript; it can contain speech recognition mistakes, so infer the intended terms.\n\n"
        if let part, part.count > 1 {
            text += "This is part \(part.index) of \(part.count) of the transcript. Summarize only this part; the parts are merged afterwards.\n\n"
        }
        text += sectionSpec(sections, custom: custom)
        text += "\n\n<transcript>\n\(transcript.trimmingCharacters(in: .whitespacesAndNewlines))\n</transcript>\n"
        return text
    }

    static func merge(partials: [String], sections: [SummarySection], custom: String) -> String {
        var text = "You are helping a student review a lecture. Below are summaries of consecutive parts of one lecture. Merge them into one summary of the whole lecture, keeping the lecture's order and removing repeats.\n\n"
        text += sectionSpec(sections, custom: custom)
        for (index, partial) in partials.enumerated() {
            text += "\n\n<part number=\"\(index + 1)\">\n\(partial.trimmingCharacters(in: .whitespacesAndNewlines))\n</part>"
        }
        return text + "\n"
    }
}

// Splits a long transcript at paragraph, then sentence, then word boundaries.
enum SummaryChunker {
    static func chunks(_ text: String, limit: Int) -> [String] {
        guard limit > 0, text.count > limit else { return [text] }
        var pieces: [String] = []
        for paragraph in text.components(separatedBy: "\n\n") where !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if paragraph.count <= limit { pieces.append(paragraph); continue }
            var sentence = ""
            for character in paragraph {
                sentence.append(character)
                if ".!?".contains(character) { pieces += split(sentence, limit: limit); sentence = "" }
            }
            if !sentence.isEmpty { pieces += split(sentence, limit: limit) }
        }
        var result: [String] = []
        var current = ""
        for piece in pieces {
            let joined = current.isEmpty ? piece : current + "\n\n" + piece
            if joined.count <= limit { current = joined } else {
                if !current.isEmpty { result.append(current) }
                current = piece
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
    private static func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var result: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let joined = current.isEmpty ? String(word) : current + " " + word
            if joined.count <= limit { current = joined; continue }
            if !current.isEmpty { result.append(current) }
            var rest = Substring(word)
            while rest.count > limit { result.append(String(rest.prefix(limit))); rest = rest.dropFirst(limit) }
            current = String(rest)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

// MARK: Files

enum SummaryFiles {
    static let suffix = " summary"

    // `<transcript name> summary.md`, next to the transcript.
    static func url(for transcript: URL) -> URL {
        transcript.deletingLastPathComponent()
            .appendingPathComponent(transcript.deletingPathExtension().lastPathComponent + suffix)
            .appendingPathExtension("md")
    }
    // A file is a summary only when its transcript sits beside it, so a session that
    // happens to be called "Week 1 summary" still shows up as a transcript.
    static func isSummary(_ url: URL, siblings: Set<String>) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension.lowercased() == "md", name.hasSuffix(suffix), name.count > suffix.count else { return false }
        return siblings.contains(String(name.dropLast(suffix.count)) + ".md") && !Core.isTranscript(at: url)
    }
    static func existing(for transcript: URL) -> URL? {
        let url = url(for: transcript)
        return isOwnedSummary(url) ? url : nil
    }
    static func isOwnedSummary(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        return header.hasPrefix("# ") && header.contains("\n\n_Summarized with ") && !Core.isTranscript(header)
    }
    static func save(_ document: String, for transcript: URL, expectedText: String) throws {
        guard try String(contentsOf: transcript, encoding: .utf8) == expectedText else {
            throw LectureError.message("The transcript changed while summarizing. Try again with the updated text.")
        }
        let target = url(for: transcript)
        // Never replace a transcript or an unrelated note that happens to have this name.
        if (try? FileManager.default.attributesOfItem(atPath: target.path)) != nil {
            guard isOwnedSummary(target) else {
                throw LectureError.message("Another file already uses this summary name. Rename the transcript, then try again.")
            }
            try Data(document.utf8).write(to: target, options: .atomic)
        } else if try !Core.exclusiveWrite(Data(document.utf8), to: target) {
            throw LectureError.message("Another file used this summary name. Try again.")
        }
    }
    static func document(body: String, transcript: URL, provider: SummaryProvider, date: Date = Date()) -> String {
        let name = transcript.deletingPathExtension().lastPathComponent
        let day = Core.dateString(date, format: "MMM d, yyyy")
        return "# \(name) summary\n\n_Summarized with \(provider.title) on \(day)._\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }
    // Model replies sometimes wrap Markdown in a code fence.
    static func clean(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}

// MARK: Keychain

// API keys live only in the macOS Keychain, as generic passwords under one service.
struct SummaryKeychain: Sendable {
    static let standard = SummaryKeychain(service: "com.bardya.nosy.summaries")
    let service: String

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func save(_ key: String, account: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LectureError.message("The key is empty.") }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            item[kSecAttrLabel as String] = "Nosy summaries key"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess {
            throw failure(status)
        }
    }
    func read(account: String) throws -> String? {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw LectureError.message("The saved key could not be read from Keychain. Save it again in Settings.")
        }
        return key
    }
    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    // What Settings shows instead of the key.
    static func masked(_ key: String) -> String {
        key.count > 8 ? "••••••••" + key.suffix(4) : "••••••••"
    }
    private func failure(_ status: OSStatus) -> Error {
        LectureError.message("Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")")
    }
}

// MARK: Detection

struct SummaryDetection: Equatable, Sendable {
    var executables: [SummaryProvider: URL] = [:]
    // nil: the server isn't running. Empty: running with no models.
    var localModels: [SummaryProvider: [String]] = [:]
    var searchPath = ""
    var checked = false

    func isAvailable(_ provider: SummaryProvider) -> Bool {
        switch provider.kind {
        case .none, .api, .builtIn: true
        case .cli: false
        case .local: localModels[provider] != nil
        }
    }
}

enum SummaryDetector {
    static func searchDirectories(home: URL, loginPath: String?) -> [URL] {
        var paths = ["/opt/homebrew/bin", "/usr/local/bin"]
        paths += [".local/bin", ".npm-global/bin", ".claude/local", ".bun/bin", ".volta/bin", ".cargo/bin"]
            .map { home.appendingPathComponent($0).path }
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []
        paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nvm.appendingPathComponent($0).appendingPathComponent("bin").path }
        paths += (loginPath ?? "").split(separator: ":").map(String.init)
        paths += ["/usr/bin", "/bin"]
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static func findExecutable(_ name: String, in directories: [URL]) -> URL? {
        for directory in directories {
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
    // Apps launched from the Dock don't get the shell's PATH; ask the login shell for it.
    static func loginShellPath(timeout: TimeInterval = 3) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '__NOSY_PATH__%s__NOSY_PATH__' \"$PATH\""]
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nosy-path-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data(), attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: temporary) else { return nil }
        defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                return nil
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        guard let reader = try? FileHandle(forReadingFrom: temporary) else { return nil }
        defer { try? reader.close() }
        let text = String(decoding: (try? reader.read(upToCount: 1_048_576)) ?? Data(), as: UTF8.self)
        let parts = text.components(separatedBy: "__NOSY_PATH__")
        return parts.count >= 3 ? parts[1] : nil
    }
    static func detectExecutables(in directories: [URL]) -> [SummaryProvider: URL] {
        var found: [SummaryProvider: URL] = [:]
        for provider in SummaryProvider.allCases {
            if case .cli(let name) = provider.kind, let url = findExecutable(name, in: directories) { found[provider] = url }
        }
        return found
    }
    static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> SummaryDetection {
        let local = await withTaskGroup(of: (SummaryProvider, [String]?).self) { group in
            for provider in [SummaryProvider.ollama, .lmStudio] {
                group.addTask { (provider, await localModels(provider)) }
            }
            var result: [SummaryProvider: [String]] = [:]
            for await (provider, models) in group { result[provider] = models }
            return result
        }
        let (directories, executables) = await Task.detached(priority: .utility) {
            let directories = searchDirectories(home: home, loginPath: loginShellPath())
            return (directories, detectExecutables(in: directories))
        }.value
        return SummaryDetection(executables: executables, localModels: local,
                                searchPath: directories.map(\.path).joined(separator: ":"), checked: true)
    }
    static func localModels(_ provider: SummaryProvider) async -> [String]? {
        guard let base = provider.localBase else { return nil }
        let url = provider == .ollama ? base.appendingPathComponent("api/tags") : base.appendingPathComponent("v1/models")
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return provider == .ollama ? parseOllamaModels(data) : parseOpenAIModels(data)
    }
    static func parseOllamaModels(_ data: Data) -> [String] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((json?["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.sorted()
    }
    static func parseOpenAIModels(_ data: Data) -> [String] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((json?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

// MARK: Running

enum SummaryError: LocalizedError, Equatable {
    case off, notInstalled(String), noKey(String), noModel, serverDown(String), timedOut, empty, contextLimit, failed(String, String)
    var errorDescription: String? {
        switch self {
        case .off: "Turn on summaries in Settings."
        case .notInstalled(let name): "\(name) isn't installed."
        case .noKey(let name): "Add your \(name) in Settings."
        case .noModel: "Pick a model for summaries in Settings."
        case .serverDown(let name): "\(name) isn't running. Open it and try again."
        case .timedOut: "The summary took too long. Try again."
        case .empty: "The provider sent back an empty summary."
        case .contextLimit: "This excerpt exceeds the summary model context. Try a shorter transcript."
        case .failed(let name, let detail): "\(name): \(SummaryError.short(detail))"
        }
    }
    static func short(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "Something went wrong."
        return line.count > 120 ? String(line.prefix(117)) + "..." : line
    }
}

struct SummaryRequest: Sendable {
    var provider: SummaryProvider
    var model: String
    var executable: URL?
    var searchPath = ""
    var apiKey: String?
    var timeout: TimeInterval = 600
    var chunkLimit: Int?
    var outputTokens = 600
    var pauseState: LlamaPauseState?
    var processActivity: (@Sendable (Bool) async -> Void)?
}

enum SummaryRunner {
    // Arguments for each CLI. The prompt always goes through stdin, so it never shows in `ps`.
    static func cliArguments(_ provider: SummaryProvider, model: String, lastMessage: URL) -> [String] {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .claudeCode:
            return ["-p", "--output-format", "text"] + (model.isEmpty ? [] : ["--model", model])
        case .codex:
            return ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--color", "never",
                    "--output-last-message", lastMessage.path] + (model.isEmpty ? [] : ["--model", model]) + ["-"]
        case .geminiCLI:
            return ["-p", "Follow the instructions above and reply with the summary only."] + (model.isEmpty ? [] : ["--model", model])
        default:
            return []
        }
    }

    static func run(_ prompt: String, request: SummaryRequest, job: TranscriptionJob) async throws -> String {
        switch request.provider.kind {
        case .none: throw SummaryError.off
        case .cli: throw SummaryError.failed(request.provider.title, "This CLI cannot be verified as a text-only completion. Choose a built-in model or an API provider instead.")
        case .builtIn:
            await request.processActivity?(true)
            do {
                let result = try await runCLI(prompt, request: request, job: job)
                await request.processActivity?(false)
                return result
            } catch {
                await request.processActivity?(false)
                throw error
            }
        case .local, .api: return try await runHTTP(prompt, request: request)
        }
    }

    private static func runCLI(_ prompt: String, request: SummaryRequest, job: TranscriptionJob) async throws -> String {
        guard let executable = request.executable else { throw SummaryError.notInstalled(request.provider.title) }
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try blockingCLI(prompt, request: request, executable: executable, job: job)
            }.value
        } onCancel: {
            job.cancel()
        }
    }

    private static func blockingCLI(_ prompt: String, request: SummaryRequest, executable: URL, job: TranscriptionJob) throws -> String {
        let provider = request.provider
        // Private scratch files are removed after the helper exits; this folder alone is not an agent sandbox.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("nosy-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let lastMessage = scratch.appendingPathComponent("last-message.txt")
        let process = Process()
        process.executableURL = executable
        // Set arguments after creating the private prompt file below.
        process.currentDirectoryURL = scratch
        process.qualityOfService = .utility
        let parent = ProcessInfo.processInfo.environment
        var environment = parent.filter { ["HOME", "TMPDIR", "LANG", "LC_ALL"].contains($0.key) }
        let existing = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [executable.deletingLastPathComponent().path, request.searchPath, existing]
            .filter { !$0.isEmpty }.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        process.environment = environment
        // Files avoid a blocked stdin writer or inherited pipe keeping quit alive after the CLI exits.
        let inputURL = scratch.appendingPathComponent("prompt.txt")
        let outputURL = scratch.appendingPathComponent("stdout.txt")
        let errorURL = scratch.appendingPathComponent("stderr.txt")
        for url in [inputURL, outputURL, errorURL] {
            guard FileManager.default.createFile(atPath: url.path, contents: url == inputURL ? Data(prompt.utf8) : Data(),
                                                attributes: [.posixPermissions: 0o600]) else {
                throw LectureError.message("Could not prepare the summary request.")
            }
        }
        process.arguments = provider.builtInModel != nil
            ? LlamaRunner.arguments(model: request.model, promptFile: inputURL, tokens: request.outputTokens)
            : cliArguments(provider, model: request.model, lastMessage: lastMessage)
        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? input.close(); try? output.close(); try? errors.close() }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let timedOut = LockedFlag()
        try job.launch(process)
        let timer = DispatchWorkItem { if process.isRunning { timedOut.set(); job.cancel() } }
        if provider.builtInModel != nil {
            var elapsed: TimeInterval = 0
            var last = ProcessInfo.processInfo.systemUptime
            while process.isRunning {
                let now = ProcessInfo.processInfo.systemUptime
                if request.pauseState?.value != true { elapsed += now - last }
                last = now
                if elapsed >= request.timeout { timedOut.set(); job.cancel(); break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        } else {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + request.timeout, execute: timer)
        }
        process.waitUntilExit()
        timer.cancel()
        if timedOut.value { throw SummaryError.timedOut }
        try job.checkCancellation()
        func read(_ url: URL, limit: Int = 16_000_000) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return String(decoding: try handle.read(upToCount: limit) ?? Data(), as: UTF8.self)
        }
        let stdout = try read(outputURL)
        guard process.terminationStatus == 0 else {
            if provider.builtInModel != nil, process.terminationStatus == 3 { throw SummaryError.contextLimit }
            let stderr = try read(errorURL, limit: 8192)
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
            throw SummaryError.failed(provider.title, detail.isEmpty ? "exited with status \(process.terminationStatus)" : detail)
        }
        let last = (try? read(lastMessage)) ?? ""
        let reply = SummaryFiles.clean(last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : last)
        guard !reply.isEmpty else { throw SummaryError.empty }
        return reply
    }

    // The request each HTTP provider expects. Keys travel only in headers.
    static func httpRequest(_ prompt: String, request: SummaryRequest) throws -> URLRequest {
        let provider = request.provider
        let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw SummaryError.noModel }
        let key = request.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if provider.kind == .api, key.isEmpty { throw SummaryError.noKey(provider.title) }
        let url: URL
        var body: [String: Any]
        var headers = ["Content-Type": "application/json"]
        let messages = [["role": "user", "content": prompt]]
        switch provider {
        case .ollama:
            url = provider.localBase!.appendingPathComponent("api/chat")
            body = ["model": model, "messages": messages, "stream": false, "options": ["num_ctx": 16_384]]
        case .lmStudio:
            url = provider.localBase!.appendingPathComponent("v1/chat/completions")
            body = ["model": model, "messages": messages]
        case .openAI:
            url = URL(string: "https://api.openai.com/v1/chat/completions")!
            body = ["model": model, "messages": messages]
            headers["Authorization"] = "Bearer \(key)"
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/messages")!
            body = ["model": model, "max_tokens": 16_000, "messages": messages]
            headers["x-api-key"] = key
            headers["anthropic-version"] = "2026-10-21"
        case .gemini:
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
            guard let name = model.addingPercentEncoding(withAllowedCharacters: allowed),
                  let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(name):generateContent") else {
                throw SummaryError.noModel
            }
            url = endpoint
            body = ["contents": [["role": "user", "parts": [["text": prompt]]]]]
            headers["x-goog-api-key"] = key
        default:
            throw SummaryError.off
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeout
        for (field, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    static func parseReply(_ data: Data, provider: SummaryProvider) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        switch provider {
        case .ollama:
            return (json["message"] as? [String: Any])?["content"] as? String
        case .lmStudio, .openAI:
            let choice = (json["choices"] as? [[String: Any]])?.first
            return (choice?["message"] as? [String: Any])?["content"] as? String
        case .anthropic:
            let blocks = (json["content"] as? [[String: Any]]) ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        case .gemini:
            let candidate = (json["candidates"] as? [[String: Any]])?.first
            let parts = ((candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            let text = parts.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }
    static func parseError(_ data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any] { return error["message"] as? String }
        return json["error"] as? String
    }

    private static func runHTTP(_ prompt: String, request: SummaryRequest) async throws -> String {
        let urlRequest = try httpRequest(prompt, request: request)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = request.timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw SummaryError.timedOut
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                if request.provider.kind == .local { throw SummaryError.serverDown(request.provider.title) }
                throw SummaryError.failed(request.provider.title, error.localizedDescription)
            default: throw SummaryError.failed(request.provider.title, error.localizedDescription)
            }
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = redacted(parseError(data) ?? HTTPURLResponse.localizedString(forStatusCode: status), key: request.apiKey)
            throw SummaryError.failed(request.provider.title, detail)
        }
        guard let reply = parseReply(data, provider: request.provider).map(SummaryFiles.clean), !reply.isEmpty else { throw SummaryError.empty }
        return reply
    }
    static func redacted(_ text: String, key: String?) -> String {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return text }
        return text.replacingOccurrences(of: key, with: "[key removed]")
    }
}

enum Summarizer {
    // One request when the transcript fits; otherwise each part, then a merge.
    static func summarize(_ transcript: String, settings: SummarySettings, request: SummaryRequest, job: TranscriptionJob,
                          beforeEachStep: @Sendable () async throws -> Void = {},
                          progress: @escaping @Sendable (_ step: Int, _ total: Int) -> Void = { _, _ in },
                          cacheRoot: URL? = nil) async throws -> String {
        if request.provider.builtInModel != nil {
            return try await LlamaRunner.summarize(transcript, settings: settings, request: request, job: job, cacheRoot: cacheRoot,
                beforeEachStep: beforeEachStep, progress: progress)
        }
        let parts = SummaryChunker.chunks(transcript, limit: request.chunkLimit ?? request.provider.chunkLimit)
        let total = parts.count == 1 ? 1 : parts.count + 1
        if parts.count == 1 {
            try await beforeEachStep()
            progress(1, 1)
            return try await SummaryRunner.run(SummaryPrompt.build(transcript: transcript, sections: settings.sections, custom: settings.custom),
                                               request: request, job: job)
        }
        var partials: [String] = []
        for (index, part) in parts.enumerated() {
            try await beforeEachStep()
            progress(index + 1, total)
            partials.append(try await SummaryRunner.run(SummaryPrompt.build(transcript: part, sections: settings.sections, custom: settings.custom,
                                                                            part: (index + 1, parts.count)), request: request, job: job))
        }
        // A long lecture can produce more partial summaries than one local context can hold.
        // Reduce bounded groups before the final merge, and fail if a provider won't condense them.
        let mergeLimit = max(4096, request.chunkLimit ?? request.provider.chunkLimit)
        var step = parts.count
        while partials.joined(separator: "\n\n").count > mergeLimit {
            let before = partials.joined(separator: "\n\n")
            let groups = SummaryChunker.chunks(before, limit: mergeLimit)
            var reduced: [String] = []
            for group in groups {
                try await beforeEachStep()
                step += 1
                progress(step, step + groups.count - reduced.count)
                reduced.append(try await SummaryRunner.run(SummaryPrompt.merge(partials: [group], sections: settings.sections, custom: settings.custom),
                                                          request: request, job: job))
            }
            guard reduced.joined(separator: "\n\n").count < before.count else {
                throw SummaryError.failed(request.provider.title, "Part summaries are too long. Try a provider with a larger context.")
            }
            partials = reduced
        }
        try await beforeEachStep()
        step += 1
        progress(step, step)
        return try await SummaryRunner.run(SummaryPrompt.merge(partials: partials, sections: settings.sections, custom: settings.custom),
                                           request: request, job: job)
    }
}

// MARK: Queue

// Runs local work one at a time, after transcription: summaries, then key moments. It remembers what each transcript is doing.
@MainActor
final class SummaryCenter: ObservableObject {
    enum Status: Equatable { case queued, running(step: Int, total: Int), waiting(String) }
    // One short line under the reader's bar. Failed notes use the error colour.
    struct Note: Equatable { let text: String; let failed: Bool }
    // Which progress table a pass reports into.
    private enum Lane { case summary, moments }

    @Published private(set) var status: [String: Status] = [:]
    @Published private(set) var errors: [String: String] = [:]
    // Find key moments progress and its latest note, keyed by transcript like summaries.
    @Published private(set) var moments: [String: Status] = [:]
    @Published private(set) var momentNotes: [String: Note] = [:]
    // Bumped whenever a summary file is written or AI markers change, so open readers reload.
    @Published private(set) var revision = 0
    @Published private(set) var detection = SummaryDetection()
    @Published private(set) var detecting = false
    // Returns why summaries should wait (a hot Mac, low battery, a local model competing with transcription).
    var waitReason: @MainActor (SummaryProvider) -> String? = { _ in nil }
    var keychain = SummaryKeychain.standard
    var defaults = UserDefaults.standard
    @Published private(set) var localModels = LocalModelStore()
    // Previews show a saved key without touching the Keychain.
    var previewKeyTail: String?

    private var queue: [URL] = []
    private var momentQueue: [(transcript: URL, paths: AppPaths)] = []
    private var worker: Task<Void, Never>?
    private var job: TranscriptionJob?
    var hasPendingWork: Bool { worker != nil || !queue.isEmpty || !momentQueue.isEmpty || localModels.hasDownloads }

    func refreshDetection() {
        guard !detecting else { return }
        detecting = true
        Task {
            detection = await SummaryDetector.detect()
            detecting = false
        }
    }
    func configurePreview(detection: SummaryDetection, keyTail: String? = nil, status: [String: Status] = [:], localModels: LocalModelStore? = nil) {
        if let localModels { self.localModels = localModels }
        self.detection = detection
        previewKeyTail = keyTail
        self.status = status
    }
    func isBusy(_ transcript: URL) -> Bool {
        let key = transcript.standardizedFileURL.path
        return status[key] != nil || moments[key] != nil
    }
    func status(for transcript: URL) -> Status? { status[transcript.standardizedFileURL.path] }
    func error(for transcript: URL) -> String? { errors[transcript.standardizedFileURL.path] }
    func momentStatus(for transcript: URL) -> Status? { moments[transcript.standardizedFileURL.path] }
    func momentNote(for transcript: URL) -> Note? { momentNotes[transcript.standardizedFileURL.path] }

    // Called when a transcript saves; only runs when the student chose automatic summaries.
    func transcriptSaved(_ transcript: URL) {
        let settings = SummarySettings.load(defaults)
        guard AIFeatures.enabled(defaults), settings.automatic, settings.provider != .off else { return }
        summarize(transcript)
    }
    func summarize(_ transcript: URL) {
        guard AIFeatures.enabled(defaults) else { return }
        let key = transcript.standardizedFileURL.path
        guard status[key] == nil else { return }
        errors[key] = nil
        guard SummarySettings.load(defaults).provider != .off else { errors[key] = SummaryError.off.localizedDescription; return }
        status[key] = .queued
        queue.append(transcript)
        pump()
    }
    // Explicit only: the reader's Find key moments button. Waits behind a running summary.
    func findMoments(_ transcript: URL, paths: AppPaths) {
        guard AIFeatures.enabled(defaults) else { return }
        let key = transcript.standardizedFileURL.path
        guard moments[key] == nil else { return }
        momentNotes[key] = nil
        guard SummarySettings.load(defaults).provider != .off else {
            momentNotes[key] = Note(text: SummaryError.off.localizedDescription, failed: true)
            return
        }
        moments[key] = .queued
        momentQueue.append((transcript, paths))
        pump()
    }
    func cancelMoments(_ transcript: URL) {
        let key = transcript.standardizedFileURL.path
        if let index = momentQueue.firstIndex(where: { $0.transcript.standardizedFileURL.path == key }) {
            momentQueue.remove(at: index)
            moments[key] = nil
            return
        }
        // Not queued, so it is the running pass: stop its process and its wait.
        if moments[key] != nil {
            job?.cancel()
            worker?.cancel()
        }
    }
    // Called after AI markers change on disk, so open readers load them again.
    func markersChanged() { revision += 1 }
    func cancelAll() {
        for transcript in queue { status[transcript.standardizedFileURL.path] = nil }
        queue.removeAll()
        for item in momentQueue { moments[item.transcript.standardizedFileURL.path] = nil }
        momentQueue.removeAll()
        job?.cancel()
        worker?.cancel()
    }
    func aiFeaturesChanged(_ enabled: Bool) {
        if !enabled { cancelAll() }
    }
    func shutdown() async {
        cancelAll()
        await worker?.value
        await localModels.shutdown()
    }

    private func pump() {
        guard worker == nil else { return }
        guard AIFeatures.enabled(defaults) else {
            for transcript in queue { status[transcript.standardizedFileURL.path] = nil }
            queue.removeAll()
            for item in momentQueue { moments[item.transcript.standardizedFileURL.path] = nil }
            momentQueue.removeAll()
            return
        }
        if !queue.isEmpty {
            let transcript = queue.removeFirst()
            let key = transcript.standardizedFileURL.path
            let job = TranscriptionJob()
            self.job = job
            worker = Task {
                do {
                    try await run(transcript, key: key, job: job)
                } catch is CancellationError {
                } catch {
                    errors[key] = (error as? SummaryError)?.localizedDescription ?? SummaryError.short(error.localizedDescription)
                }
                status[key] = nil
                worker = nil
                self.job = nil
                pump()
            }
        } else if !momentQueue.isEmpty {
            let item = momentQueue.removeFirst()
            let key = item.transcript.standardizedFileURL.path
            let job = TranscriptionJob()
            self.job = job
            worker = Task {
                do {
                    try await runMoments(item.transcript, paths: item.paths, key: key, job: job)
                } catch is CancellationError {
                } catch {
                    momentNotes[key] = Note(text: SummaryError.short((error as? LocalizedError)?.errorDescription ?? error.localizedDescription), failed: true)
                }
                moments[key] = nil
                worker = nil
                self.job = nil
                pump()
            }
        }
    }

    private func run(_ transcript: URL, key: String, job: TranscriptionJob) async throws {
        guard AIFeatures.enabled(defaults) else { throw CancellationError() }
        let settings = SummarySettings.load(defaults)
        guard settings.provider != .off else { throw SummaryError.off }
        let pauseState = LlamaPauseState()
        let request = try await providerRequest(settings, pauseState: pauseState)
        guard AIFeatures.enabled(defaults) else { throw CancellationError() }
        let markdown = try await Task.detached(priority: .utility) { try String(contentsOf: transcript, encoding: .utf8) }.value
        guard Core.wordCount(markdown) > 0 else { throw LectureError.message("This transcript has no speech to summarize.") }
        let provider = settings.provider
        // Published changes stop the child synchronously before recording starts. The periodic
        // monitor also handles temperature, battery and transcription changes during a pass.
        let guards = startGuard(provider, lane: .summary, key: key, job: job, pauseState: pauseState)
        defer {
            guards.activity?.cancel(); guards.monitor?.cancel(); job.resume()
            if let model = provider.builtInModel { localModels.setLoaded(model, false) }
        }
        let body = try await Summarizer.summarize(markdown, settings: settings, request: request, job: job,
            beforeEachStep: { [weak self] in try await self?.waitUntilReady(provider, lane: .summary, key: key) },
            progress: { [weak self] step, total in
                Task { @MainActor in
                    guard let self, self.job === job, self.status[key] != nil else { return }
                    self.status[key] = .running(step: step, total: total)
                }
            }, cacheRoot: localModels.root)
        let document = SummaryFiles.document(body: body, transcript: transcript, provider: provider)
        try Task.checkCancellation()
        guard AIFeatures.enabled(defaults) else { throw CancellationError() }
        try await Task.detached(priority: .utility) { try SummaryFiles.save(document, for: transcript, expectedText: markdown) }.value
        revision += 1
    }

    // Find key moments: the same provider and pause rules as summaries, one model call per chunk.
    private func runMoments(_ transcript: URL, paths: AppPaths, key: String, job: TranscriptionJob) async throws {
        guard AIFeatures.enabled(defaults) else { throw CancellationError() }
        let settings = SummarySettings.load(defaults)
        guard settings.provider != .off else { throw SummaryError.off }
        let pauseState = LlamaPauseState()
        var request = try await providerRequest(settings, pauseState: pauseState)
        guard AIFeatures.enabled(defaults) else { throw CancellationError() }
        request.outputTokens = KeyMoments.outputTokens
        let finalRequest = request
        let provider = settings.provider
        let guards = startGuard(provider, lane: .moments, key: key, job: job, pauseState: pauseState)
        defer {
            guards.activity?.cancel(); guards.monitor?.cancel(); job.resume()
            if let model = provider.builtInModel { localModels.setLoaded(model, false) }
        }
        let plan = try await Task.detached(priority: .utility) { try KeyMoments.plan(transcript: transcript, paths: paths) }.value
        let markers = try await KeyMoments.find(units: plan.units, duration: plan.duration, manualTimes: plan.manualTimes, title: plan.title,
            report: { [weak self] current, total in
                try await self?.waitUntilReady(provider, lane: .moments, key: key)
                await self?.reportMoments(key, job: job, current: current, total: total)
            },
            complete: { prompt in try await SummaryRunner.run(prompt, request: finalRequest, job: job) })
        try Task.checkCancellation()
        guard AIFeatures.enabled(defaults) else { throw CancellationError() }
        try await Task.detached(priority: .utility) { try KeyMomentStore.replace(markers, transcript: transcript, paths: paths) }.value
        momentNotes[key] = markers.isEmpty ? Note(text: "No clear key moments found.", failed: false) : nil
        revision += 1
    }

    private func reportMoments(_ key: String, job: TranscriptionJob, current: Int, total: Int) {
        guard self.job === job, moments[key] != nil else { return }
        moments[key] = .running(step: current, total: total)
    }

    // The request for the chosen provider. Built in and local engines are checked here before any run.
    private func providerRequest(_ settings: SummarySettings, pauseState: LlamaPauseState) async throws -> SummaryRequest {
        if case .cli = settings.provider.kind {
            throw SummaryError.failed(settings.provider.title, "This CLI cannot be verified as a text-only completion. Choose a built-in model or an API provider instead.")
        }
        if !detection.checked, settings.provider.kind != .api, settings.provider.builtInModel == nil {
            detection = await SummaryDetector.detect()
        }
        var request = SummaryRequest(provider: settings.provider, model: settings.model,
                                     executable: detection.executables[settings.provider], searchPath: detection.searchPath)
        switch settings.provider.kind {
        case .builtIn:
            guard let model = settings.provider.builtInModel, localModels.available(model) else {
                throw SummaryError.failed(settings.provider.title, "Download this model in Settings, then try again.")
            }
            request.pauseState = pauseState
            request.executable = LlamaRunner.bundledHelper
            request.model = localModels.file(model).path
            request.processActivity = { [weak self] active in
                await self?.localModels.setLoaded(model, active)
            }
            guard FileManager.default.isExecutableFile(atPath: LlamaRunner.bundledHelper.path) else {
                throw SummaryError.notInstalled("The built in summary engine")
            }
        case .cli:
            if request.executable == nil { detection = await SummaryDetector.detect() }
            request.executable = detection.executables[settings.provider]
            guard request.executable != nil else { throw SummaryError.notInstalled(settings.provider.title) }
        case .api:
            let keychain = keychain
            let account = settings.provider.rawValue
            request.apiKey = try await Task.detached { try keychain.read(account: account) }.value
            guard request.apiKey != nil else { throw SummaryError.noKey(settings.provider.title) }
        case .local:
            guard !settings.model.isEmpty else { throw SummaryError.noModel }
        case .none:
            throw SummaryError.off
        }
        return request
    }

    // Local passes pause while recording, transcribing or a hot Mac needs the machine. Cloud and CLI passes never pause.
    private func startGuard(_ provider: SummaryProvider, lane: Lane, key: String, job: TranscriptionJob,
                            pauseState: LlamaPauseState) -> (activity: AnyCancellable?, monitor: Task<Void, Never>?) {
        guard provider.builtInModel != nil else { return (nil, nil) }
        let activity = Self.observeLocalActivity(model: AppModel.shared, job: job, pauseState: pauseState)
        let monitor = Task { [weak self] in
            var previousStatus: Status?
            while !Task.isCancelled {
                guard let self else { return }
                if let reason = self.localWaitReason() ?? self.waitReason(provider) {
                    pauseState.set(true); job.suspend()
                    if case .running = self.phase(lane, key) { previousStatus = self.phase(lane, key); self.setPhase(lane, key, .waiting(reason)) }
                } else {
                    pauseState.set(false); job.resume()
                    if let previousStatus, case .waiting = self.phase(lane, key) { self.setPhase(lane, key, previousStatus) }
                    previousStatus = nil
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return (activity, monitor)
    }

    private func phase(_ lane: Lane, _ key: String) -> Status? { lane == .summary ? status[key] : moments[key] }
    private func setPhase(_ lane: Lane, _ key: String, _ value: Status?) {
        if lane == .summary { status[key] = value } else { moments[key] = value }
    }

    // Respects the same back-off as transcription: wait while the Mac is hot or the battery is low.
    private func waitUntilReady(_ provider: SummaryProvider, lane: Lane, key: String) async throws {
        guard AIFeatures.enabled(defaults) else { throw CancellationError() }
        while let reason = (provider.builtInModel == nil ? nil : localWaitReason()) ?? waitReason(provider) {
            guard AIFeatures.enabled(defaults) else { throw CancellationError() }
            setPhase(lane, key, .waiting(reason))
            try await Task.sleep(for: .seconds(15))
        }
        try Task.checkCancellation()
    }

    static func observeLocalActivity(model: AppModel, job: TranscriptionJob, pauseState: LlamaPauseState? = nil) -> AnyCancellable {
        model.$phase.combineLatest(model.$transitioning, model.$active, model.$queue).sink { phase, transitioning, active, queue in
            if phase == .recording || transitioning || active != nil || !queue.isEmpty { pauseState?.set(true); job.suspend() }
        }
    }

    private func localWaitReason() -> String? {
        let model = AppModel.shared
        if model.recording || model.transitioning { return "Waiting for recording to finish" }
        if model.active != nil || !model.queue.isEmpty { return "Waiting for transcription" }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "Low Power Mode is on" }
        let power = Core.powerState()
        return Core.stressReason(thermal: ProcessInfo.processInfo.thermalState, onBattery: power.onBattery, percent: power.percent)
    }
}
