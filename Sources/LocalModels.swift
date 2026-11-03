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
    static func transfer(url: URL, partial: URL, expectedBytes: Int64, checksum: String, job: TranscriptionJob, paths: AppPaths,
                         verifying: @escaping @Sendable () -> Void = {}) async throws {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try paths.createSupportDirectory(partial.deletingLastPathComponent())
                guard paths.safeSupportItem(partial.deletingLastPathComponent(), directory: true) else { throw LectureError.message("Unsafe model storage.") }
                guard paths.safeSupportDestination(partial) else { throw LectureError.message("Unsafe model storage.") }
                if Core.fileSize(partial) > expectedBytes { try paths.removeSupportFile(partial) }
                if Core.fileSize(partial) < expectedBytes {
                    let log = partial.appendingPathExtension("log")
                    guard paths.safeSupportDestination(log) else { throw LectureError.message("Unsafe model storage.") }
                    FileManager.default.createFile(atPath: log.path, contents: Data(), attributes: [.posixPermissions: 0o600])
                    defer { try? paths.removeSupportFile(log) }
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
                            try? paths.removeSupportFile(partial)
                            continue
                        }
                        throw LectureError.message("The model download stopped. Check disk space and your connection, then resume.")
                    }
                }
                try job.checkCancellation()
                verifying()
                guard Core.fileSize(partial) == expectedBytes, try sha256(partial, job: job) == checksum else {
                    try? paths.removeSupportFile(partial)
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
    // Partial-download bytes per model. Kept current by the progress tick, so views never touch the disk.
    @Published private var partialSizes: [String: Int64] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var jobs: [String: TranscriptionJob] = [:]
    // Full scans: one in flight at a time, at most one start per second, and only the latest result publishes.
    private var diskScan: Task<Void, Never>?
    private var diskScanRequested = false
    private var diskScanGeneration = 0
    private var nextDiskScan: ContinuousClock.Instant?
    var hasDownloads: Bool { !tasks.isEmpty }

    init(root: URL = AppPaths().support.appendingPathComponent("models/llm", isDirectory: true)) {
        self.root = root
        refresh()
    }
    private var safetyPaths: AppPaths {
        let standard = AppPaths()
        let rootPath = root.standardizedFileURL.path
        let supportPath = standard.support.standardizedFileURL.path
        if rootPath == supportPath || rootPath.hasPrefix(supportPath + "/") { return standard }
        return AppPaths(environment: ["NOSY_SUPPORT_DIR": root.path, "NOSY_TRANSCRIPTS_DIR": standard.transcripts.path])
    }
    func file(_ model: LocalModel) -> URL { root.appendingPathComponent(model.fileName) }
    func partial(_ model: LocalModel) -> URL { file(model).appendingPathExtension("part") }
    func partialBytes(_ model: LocalModel) -> Int64 { partialSizes[model.id] ?? 0 }
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
        requestDiskScan()
    }
    // Scans the whole model folder off the main actor. Requests made while a scan runs queue one rerun.
    private func requestDiskScan() {
        // Snapshot previews set their own disk figures, which a real scan would overwrite.
        guard !Snapshot.isRunning else { return }
        diskScanGeneration += 1
        diskScanRequested = true
        guard diskScan == nil else { return }
        // Partial files sit directly in the model folder, so their names identify each model.
        let partialNames = Dictionary(uniqueKeysWithValues: LocalModel.all.map { (partial($0).lastPathComponent, $0.id) })
        diskScan = Task { [self] in
            while diskScanRequested {
                if let nextDiskScan, ContinuousClock.now < nextDiskScan {
                    try? await Task.sleep(until: nextDiskScan, clock: .continuous)
                }
                diskScanRequested = false
                let generation = diskScanGeneration
                nextDiskScan = ContinuousClock.now.advanced(by: .seconds(1))
                let root = self.root
                let scan = await Task.detached(priority: .utility) {
                    LocalModelStore.scanDisk(root, partialNames: partialNames)
                }.value
                if generation == diskScanGeneration {
                    var partials = scan.partials
                    var total = scan.total
                    // Progress can advance while the full scan runs. Keep its newest partial
                    // readings and adjust the scan's total by the same delta.
                    for id in tasks.keys {
                        guard let latest = partialSizes[id] else { continue }
                        total += latest - (partials[id] ?? 0)
                        partials[id] = latest
                    }
                    if partialSizes != partials { partialSizes = partials }
                    if total != diskBytes { diskBytes = max(0, total) }
                }
            }
            diskScan = nil
        }
    }
    private struct DiskScan: Sendable {
        let total: Int64
        let partials: [String: Int64]
    }
    nonisolated private static func scanDisk(_ root: URL, partialNames: [String: String]) -> DiskScan {
        var total: Int64 = 0
        var partials: [String: Int64] = [:]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = files?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let size = Core.fileSize(url)
            total += size
            if let id = partialNames[url.lastPathComponent] { partials[id] = size }
        }
        return DiskScan(total: total, partials: partials)
    }
    // Applies one progress reading to the cached partial size and the disk total, without a rescan.
    private func adjustPartial(_ model: LocalModel, to bytes: Int64) {
        let previous = partialSizes[model.id] ?? 0
        guard bytes != previous else { return }
        partialSizes[model.id] = bytes
        diskBytes += bytes - previous
    }
    func download(_ model: LocalModel, source: URL? = nil) {
        guard tasks[model.id] == nil, state(model) != .loaded else { return }
        let job = TranscriptionJob()
        jobs[model.id] = job
        let bytes = Core.fileSize(partial(model))
        adjustPartial(model, to: bytes)
        states[model.id] = .downloading(bytes)
        tasks[model.id] = Task { [self] in
            let ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled, let self else { return }
                    // Only the active partial file is measured, and off the main actor.
                    let url = partial(model)
                    let size = await Task.detached(priority: .utility) { Core.fileSize(url) }.value
                    guard !Task.isCancelled, case .downloading = state(model) else { continue }
                    adjustPartial(model, to: size)
                    if state(model) != .downloading(size) { states[model.id] = .downloading(size) }
                }
            }
            defer { ticker.cancel(); tasks[model.id] = nil; jobs[model.id] = nil; requestDiskScan() }
            do {
                try await LocalModelDownload.transfer(url: source ?? model.url, partial: partial(model), expectedBytes: model.bytes,
                    checksum: model.sha256, job: job, paths: safetyPaths, verifying: { [weak self] in
                        Task { @MainActor in
                            guard let self, self.tasks[model.id] != nil, case .downloading = self.state(model) else { return }
                            self.states[model.id] = .verifying
                        }
                    })
                try job.checkCancellation()
                let target = file(model)
                if FileManager.default.fileExists(atPath: target.path) { try safetyPaths.removeSupportFile(target) }
                guard safetyPaths.safeSupportItem(partial(model), directory: false), safetyPaths.safeSupportItem(target.deletingLastPathComponent(), directory: true) else { throw LectureError.message("Unsafe model storage.") }
                try FileManager.default.moveItem(at: partial(model), to: target)
                guard safetyPaths.safeSupportItem(target, directory: false) else { throw LectureError.message("Unsafe model file.") }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                let modified = try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
                guard safetyPaths.safeSupportDestination(receipt(model)) else { throw LectureError.message("Unsafe model storage.") }
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
            try safetyPaths.removeSupportFile(url)
        }
        adjustPartial(model, to: 0)
        states[model.id] = .notDownloaded
        requestDiskScan()
    }
    func setLoaded(_ model: LocalModel, _ loaded: Bool) {
        states[model.id] = loaded ? .loaded : (available(model) ? .downloaded : .notDownloaded)
        if !loaded { requestDiskScan() }
    }
    func configurePreview(_ model: LocalModel, state: State, diskBytes: Int64) {
        states[model.id] = state; self.diskBytes = diskBytes
    }
}
