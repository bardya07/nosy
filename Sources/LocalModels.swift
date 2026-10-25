import Foundation
import CryptoKit
import Combine

struct LocalModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let fileName: String
    let repository: String
    let revision: String
    let bytes: Int64
    let sha256: String
    var url: URL { URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)")! }
    var sizeLabel: String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
    var ramNote: String { id == "smol" ? "Smaller model for Macs with 8 GB of memory." : "Recommended for Macs with more than 8 GB of memory." }
    static let qwen = LocalModel(id: "qwen", name: "Qwen3 4B", fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        repository: "unsloth/Qwen3-4B-Instruct-2507-GGUF", revision: "a06e946bb6b655725eafa393f4a9745d460374c9",
        bytes: 2_497_281_120, sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597")
    static let smol = LocalModel(id: "smol", name: "SmolLM3 3B", fileName: "SmolLM3-Q4_K_M.gguf",
        repository: "ggml-org/SmolLM3-3B-GGUF", revision: "4965cb60b150737b68a0408c36aeefb65078f894",
        bytes: 1_915_305_312, sha256: "8334b850b7bd46238c16b0c550df2138f0889bf433809008cc17a8b05761863e")
    static let all = [qwen, smol]
    static func recommended(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> LocalModel {
        memory <= 8 * 1024 * 1024 * 1024 ? smol : qwen
    }
}

// curl's Range support keeps partial bytes across cancellation, app restarts and network failures.
// Only a completed, size checked, SHA256 checked file can receive the final model name.
enum LocalModelDownload {
    static func sha256(_ url: URL, job: TranscriptionJob = TranscriptionJob()) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while true {
            try job.checkCancellation()
            let block = try input.read(upToCount: 1_048_576) ?? Data()
            if block.isEmpty { break }
            hash.update(data: block)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func transfer(url: URL, partial: URL, expectedBytes: Int64, checksum: String, job: TranscriptionJob,
                         verifying: @escaping @Sendable () -> Void = {}) async throws {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                if Core.fileSize(partial) > expectedBytes { try FileManager.default.removeItem(at: partial) }
                if Core.fileSize(partial) < expectedBytes {
                    let log = partial.appendingPathExtension("log")
                    FileManager.default.createFile(atPath: log.path, contents: Data(), attributes: [.posixPermissions: 0o600])
                    defer { try? FileManager.default.removeItem(at: log) }
                    let errors = try FileHandle(forWritingTo: log)
                    defer { try? errors.close() }
                    for attempt in 0...1 {
                        try job.checkCancellation()
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                        process.arguments = ["--fail", "--location", "--silent", "--show-error", "--retry", "2", "--connect-timeout", "30",
                                             "--speed-limit", "1024", "--speed-time", "60", "--continue-at", "-", "--output", partial.path, url.absoluteString]
                        process.qualityOfService = .utility
                        process.standardOutput = FileHandle.nullDevice
                        process.standardInput = FileHandle.nullDevice
                        process.standardError = errors
                        try job.launch(process)
                        process.waitUntilExit()
                        try job.checkCancellation()
                        if process.terminationStatus == 0 { break }
                        // Range ignored, changed remote, or an invalid partial: restart once safely.
                        if attempt == 0, [33, 36].contains(process.terminationStatus) {
                            try? FileManager.default.removeItem(at: partial)
                            continue
                        }
                        throw LectureError.message("The model download stopped. Check disk space and your connection, then resume.")
                    }
                }
                try job.checkCancellation()
                verifying()
                guard Core.fileSize(partial) == expectedBytes, try sha256(partial, job: job) == checksum else {
                    try? FileManager.default.removeItem(at: partial)
                    throw LectureError.message("SHA256 verification failed. Download the model again.")
                }
            }.value
        } onCancel: { job.cancel() }
    }
}

@MainActor
final class LocalModelStore: ObservableObject {
    enum State: Equatable {
        case notDownloaded, downloading(Int64), verifying, downloaded, loaded, error(String)
        var title: String {
            switch self {
            case .notDownloaded: "Not downloaded"
            case .downloading: "Downloading"
            case .verifying: "Verifying SHA256"
            case .downloaded: "Downloaded"
            case .loaded: "Loaded (in use right now)"
            case .error: "Error"
            }
        }
        var busy: Bool { if case .downloading = self { return true }; return self == .verifying }
    }
    struct Receipt: Codable {
        let checksum: String
        let bytes: Int64
        let modified: Date
    }
    let root: URL
    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var diskBytes: Int64 = 0
    private var tasks: [String: Task<Void, Never>] = [:]
    private var jobs: [String: TranscriptionJob] = [:]
    var hasDownloads: Bool { !tasks.isEmpty }

    init(root: URL = AppPaths().support.appendingPathComponent("models/llm", isDirectory: true)) {
        self.root = root
        refresh()
    }
    func file(_ model: LocalModel) -> URL { root.appendingPathComponent(model.fileName) }
    func partial(_ model: LocalModel) -> URL { file(model).appendingPathExtension("part") }
    private func receipt(_ model: LocalModel) -> URL { file(model).appendingPathExtension("verified.json") }
    func state(_ model: LocalModel) -> State { states[model.id] ?? .notDownloaded }
    func available(_ model: LocalModel) -> Bool {
        guard let data = try? Data(contentsOf: receipt(model)),
              let proof = try? JSONDecoder().decode(Receipt.self, from: data), proof.checksum == model.sha256,
              proof.bytes == model.bytes, Core.fileSize(file(model)) == model.bytes,
              let values = try? file(model).resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, values.contentModificationDate == proof.modified else { return false }
        return true
    }
    func refresh() {
        for model in LocalModel.all where tasks[model.id] == nil && state(model) != .loaded {
            states[model.id] = available(model) ? .downloaded : .notDownloaded
        }
        updateDisk()
    }
    private func updateDisk() {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        diskBytes = 0
        while let url = files?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { diskBytes += Core.fileSize(url) }
        }
    }
    func download(_ model: LocalModel, source: URL? = nil) {
        guard tasks[model.id] == nil, state(model) != .loaded else { return }
        let job = TranscriptionJob()
        jobs[model.id] = job
        states[model.id] = .downloading(Core.fileSize(partial(model)))
        tasks[model.id] = Task { [self] in
            let ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled, let self else { return }
                    if case .downloading = state(model) { states[model.id] = .downloading(Core.fileSize(partial(model))); updateDisk() }
                }
            }
            defer { ticker.cancel(); tasks[model.id] = nil; jobs[model.id] = nil; updateDisk() }
            do {
                try await LocalModelDownload.transfer(url: source ?? model.url, partial: partial(model), expectedBytes: model.bytes,
                    checksum: model.sha256, job: job, verifying: { [weak self] in
                        Task { @MainActor in
                            guard let self, self.tasks[model.id] != nil, case .downloading = self.state(model) else { return }
                            self.states[model.id] = .verifying
                        }
                    })
                try job.checkCancellation()
                let target = file(model)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: partial(model), to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                let modified = try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
                try JSONEncoder().encode(Receipt(checksum: model.sha256, bytes: model.bytes, modified: modified)).write(to: receipt(model), options: .atomic)
                states[model.id] = .downloaded
            } catch is CancellationError { states[model.id] = .notDownloaded }
            catch { states[model.id] = .error(SummaryError.short(error.localizedDescription)) }
        }
    }
    func cancel(_ model: LocalModel) { jobs[model.id]?.cancel(); tasks[model.id]?.cancel() }
    func shutdown() async {
        for job in jobs.values { job.cancel() }
        let pending = Array(tasks.values)
        for task in pending { task.cancel() }
        for task in pending { await task.value }
    }
    func remove(_ model: LocalModel) throws {
        guard tasks[model.id] == nil, state(model) != .loaded else { return }
        for url in [file(model), partial(model), receipt(model)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        // Map notes are specific to this model. Removal frees those too.
        try? FileManager.default.removeItem(at: root.appendingPathComponent("notes/\(model.id)"))
        states[model.id] = .notDownloaded
        updateDisk()
    }
    func setLoaded(_ model: LocalModel, _ loaded: Bool) {
        states[model.id] = loaded ? .loaded : (available(model) ? .downloaded : .notDownloaded)
        if !loaded { updateDisk() }
    }
    func configurePreview(_ model: LocalModel, state: State, diskBytes: Int64) {
        states[model.id] = state; self.diskBytes = diskBytes
    }
}
