import AppKit
import Foundation
import Darwin

// Adds or removes Nosy's transcript server in Claude Desktop's config. Only the mcpServers.nosy
// entry changes; every other key is kept. Nothing is written when the file is not valid JSON.
enum ClaudeDesktopConfig {
    static let serverName = "nosy"

    enum Failure: LocalizedError, Equatable {
        case unreadable
        case serversNotObject
        case helperMissing
        case changed

        var errorDescription: String? {
            switch self {
            case .unreadable: "Claude Desktop's settings file is not valid JSON, so Nosy left it unchanged. Fix the file, then try again."
            case .serversNotObject: "The mcpServers entry in Claude Desktop's settings is not an object, so Nosy left the file unchanged."
            case .helperMissing: "Nosy's connector is missing from this copy of the app. Reinstall Nosy, then try again."
            case .changed: "Claude Desktop's settings changed during setup. Try again so Nosy can keep those changes."
            }
        }
    }

    static func isAdded(_ data: Data?, command: String? = nil) throws -> Bool {
        let entry = try servers(in: load(data))?[serverName]
        guard let command else { return entry != nil }
        return (entry as? [String: Any])?["command"] as? String == command
    }

    // The new file contents, or nil when the entry already points at this command.
    static func adding(to data: Data?, command: String) throws -> Data? {
        var root = try load(data)
        var servers = try servers(in: root) ?? [:]
        if let existing = servers[serverName] as? [String: Any], existing.count == 1, existing["command"] as? String == command {
            return nil
        }
        servers[serverName] = ["command": command]
        root["mcpServers"] = servers
        return try encode(root)
    }

    // The new file contents, or nil when there is no Nosy entry to remove.
    static func removing(from data: Data?) throws -> Data? {
        var root = try load(data)
        guard var servers = try servers(in: root), servers[serverName] != nil else { return nil }
        servers[serverName] = nil
        root["mcpServers"] = servers
        return try encode(root)
    }

    // What to paste into other apps and into a terminal for Claude Code.
    static func setupText(command: String) -> String {
        let snippet: [String: Any] = ["mcpServers": [serverName: ["command": command]]]
        let json = (try? JSONSerialization.data(withJSONObject: snippet, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return """
        For Claude Desktop, Cursor and other apps that read mcpServers, add this to their config file:
        \(json)

        For Claude Code, run this in a terminal:
        claude mcp add \(serverName) -- \(shellQuoted(command))
        """
    }

    static func shellQuoted(_ path: String) -> String {
        let plain = path.unicodeScalars.allSatisfy { scalar in
            (scalar.value < 128 && (CharacterSet.alphanumerics.contains(scalar))) || "/._-+:@".unicodeScalars.contains(scalar)
        }
        if plain { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // An empty or missing file counts as an empty object.
    private static func load(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] else {
            throw Failure.unreadable
        }
        return root
    }

    private static func servers(in root: [String: Any]) throws -> [String: Any]? {
        guard let value = root["mcpServers"] else { return nil }
        guard let servers = value as? [String: Any] else { throw Failure.serversNotObject }
        return servers
    }

    private static func encode(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
    }
}

// Claude Desktop itself, found by its bundle identifier. Nosy quits it gently and opens it again.
// It never force quits, so an unsaved prompt or a dialog in Claude Desktop is never lost.
enum ClaudeDesktopApp {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let downloadURL = URL(string: "https://claude.ai/download")!

    struct Status: Equatable, Sendable {
        var installed: Bool
        var running: Bool
    }

    enum RestartOutcome: Equatable {
        case restarted
        case notRunning
        case stillRunning
        case failed
    }

    @MainActor static func status() -> Status {
        Status(installed: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil,
               running: stillRunning())
    }

    @MainActor static func stillRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    // Quits a running Claude Desktop, waits for it to finish, then opens it again. A copy that is not running is left alone.
    @MainActor static func restart() async -> RestartOutcome {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        guard !running.isEmpty else { return .notRunning }
        let url = running.first?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        // terminate() asks the app to quit, so it can finish or ask first.
        for app in running { _ = app.terminate() }
        // About fifteen seconds for Claude Desktop to close on its own.
        var waits = 0
        while stillRunning(), waits < 75 {
            try? await Task.sleep(for: .milliseconds(200))
            waits += 1
        }
        guard !stillRunning() else { return .stillRunning }
        guard let url else { return .failed }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return .restarted
        } catch {
            return .failed
        }
    }
}

// The words on the Connect your AI pane. They live here so tests can check them.
enum ConnectionCopy {
    static let connected = "Connected to Claude Desktop"
    static let notConnected = "Not connected yet"
    static let notInstalled = "Claude Desktop is not installed"
    static let needsFixing = "Claude Desktop settings need fixing"
    static let steps = ["Quit and reopen Claude Desktop.", "Ask: \u{201C}Summarize my latest lecture\u{201D}"]
    static let examplePrompt = "Summarize my latest lecture"
    static let copiedPrompt = "Copied the example prompt."
    static let closedNote = "Claude Desktop is not open. Open it to use Nosy."
    static let installNote = "Install Claude Desktop, then come back here to connect Nosy."
    static let downloadLabel = "Get Claude Desktop"
    static let removedNote = "Removed. Restart Claude Desktop to apply."

    static func title(_ status: ClaudeConnector.Status, installed: Bool) -> String {
        switch status {
        case .added: connected
        case .notAdded: installed ? notConnected : notInstalled
        case .unreadable: needsFixing
        }
    }
}

// The Settings section's file work. Paths are injectable so previews and tests never touch the real config.
struct ClaudeConnector: Sendable {
    enum Status: Equatable, Sendable {
        case added
        case notAdded
        case unreadable(String)
    }

    let configURL: URL
    let helperURL: URL
    // Whether Claude Desktop is installed and open. Previews replace this so they never depend on this Mac.
    var desktop: @MainActor @Sendable () -> ClaudeDesktopApp.Status = { ClaudeDesktopApp.status() }

    static var standard: ClaudeConnector {
        ClaudeConnector(
            configURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"),
            helperURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/nosy-mcp"))
    }

    var helperPath: String { helperURL.path }

    func status() -> Status {
        do {
            return try ClaudeDesktopConfig.isAdded(readConfig(), command: helperPath) ? .added : .notAdded
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    func add() throws {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { throw ClaudeDesktopConfig.Failure.helperMissing }
        let original = try readConfig()
        guard let updated = try ClaudeDesktopConfig.adding(to: original, command: helperPath) else { return }
        try replace(original, with: updated)
    }

    func remove() throws {
        let original = try readConfig()
        guard let updated = try ClaudeDesktopConfig.removing(from: original) else { return }
        try replace(original, with: updated)
    }

    // A missing file reads as nil. A file that exists but cannot be read throws, so it is never overwritten.
    private func readConfig() throws -> Data? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        return try Data(contentsOf: configURL)
    }

    private func replace(_ original: Data?, with updated: Data) throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let original {
            // Keep the settings as they were before this change. An existing backup is never overwritten.
            try writePrivate(original, to: backupURL())
        }
        let temporary = configURL.deletingLastPathComponent().appendingPathComponent(".nosy-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writePrivate(updated, to: temporary)
        guard try readConfig() == original else { throw ClaudeDesktopConfig.Failure.changed }
        let result = temporary.path.withCString { from in configURL.path.withCString { to in rename(from, to) } }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func backupURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())
        let folder = configURL.deletingLastPathComponent()
        // Two changes in the same millisecond must not collide (the write never overwrites).
        var candidate = folder.appendingPathComponent("claude_desktop_config.backup-\(stamp).json")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("claude_desktop_config.backup-\(stamp)-\(index).json")
            index += 1
        }
        return candidate
    }
}
