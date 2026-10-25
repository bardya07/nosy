import Foundation

// Tests for the Claude connector: JSON-RPC handling of nosy-mcp, path safety on the transcripts folder,
// and the Claude Desktop config merge. Compiled with Connector/MCPServer.swift, Connector/TranscriptStore.swift
// and Sources/ClaudeConnector.swift. Uses only temporary folders.
@main
enum ConnectorTests {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("nosy-connector-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let transcripts = root.appendingPathComponent("transcripts", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try makeFixtures(transcripts: transcripts, outside: outside)
        let server = MCPServer(store: TranscriptStore(root: transcripts))
        var assertions = 0
        func check(_ value: Bool, _ message: String) {
            assertions += 1
            guard value else { fatalError("FAIL: \(message)") }
        }

        // JSON-RPC lifecycle and errors
        let initialized = object(server.respond(to: rpc(1, "initialize", ["protocolVersion": "2025-06-18"])))
        let initResult = dict(initialized["result"])
        check(initResult["protocolVersion"] as? String == "2025-06-18", "initialize echoes a supported protocol version")
        check(dict(initResult["capabilities"])["tools"] != nil, "initialize declares tools")
        check(dict(initResult["serverInfo"])["name"] as? String == "nosy", "initialize names the server nosy")
        check(initialized["id"] as? Int == 1, "reply keeps the request id")
        let unknownVersion = object(server.respond(to: rpc(2, "initialize", ["protocolVersion": "1999-01-01"])))
        check(dict(unknownVersion["result"])["protocolVersion"] as? String == MCPServer.latestProtocolVersion,
              "initialize offers the latest version for an unknown one")
        check(server.respond(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil, "notifications get no reply")
        check(server.respond(to: "   ") == nil, "blank lines get no reply")
        check(dict(object(server.respond(to: rpc(3, "ping", [:])))["result"]).isEmpty, "ping returns an empty result")
        let listed = object(server.respond(to: rpc(4, "tools/list", [:])))
        let tools = (dict(listed["result"])["tools"] as? [[String: Any]]) ?? []
        check(tools.compactMap { $0["name"] as? String } == ["list_folders", "list_transcripts", "read_transcript", "search_transcripts"],
              "tools/list names the four read tools")
        check(tools.allSatisfy { dict($0["annotations"])["readOnlyHint"] as? Bool == true }, "every tool is marked read only")
        check(dict(object(server.respond(to: rpc(5, "resources/list", [:])))["error"])["code"] as? Int == -32601,
              "unknown methods get method not found")
        let parseError = object(server.respond(to: "{not json"))
        check(dict(parseError["error"])["code"] as? Int == -32700 && parseError["id"] is NSNull, "bad JSON gets a parse error with a null id")
        check(dict(object(server.respond(to: rpc(6, "tools/call", ["name": "delete_everything", "arguments": [:]])))["error"])["code"] as? Int == -32602,
              "unknown tools are a protocol error")
        let batch = server.respond(to: "[" + rpc(7, "ping", [:]) + "," + #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "]")
        check((batchReplies(batch)).count == 1, "a batch gets one reply per request")
        check(server.respond(to: "[]") != nil, "an empty batch is an invalid request")

        // Tools
        let folders = call(server, "list_folders", [:])
        check(!folders.isError && folders.text.contains("\"name\":\"MBB322\"") && folders.text.contains("\"transcripts\":1"),
              "list_folders counts transcripts, skipping summaries and hidden files")
        check(!folders.text.contains("Escape") && !folders.text.contains("Hidden"), "list_folders hides symlinks and hidden folders leaving the root")
        let all = call(server, "list_transcripts", [:])
        check(!all.isError && all.text.contains("\"date\":\"2026-10-23 16:13\"") && all.text.contains("\"duration\":\"1 min\""),
              "list_transcripts reads date and length from the header")
        check(all.text.range(of: "2026-10-23")!.lowerBound < all.text.range(of: "2026-10-20")!.lowerBound, "list_transcripts is newest first")
        check(!all.text.contains("summary.md") && !all.text.contains("leak"), "list_transcripts skips summaries and outside links")
        check(!call(server, "list_transcripts", ["folder": "Rehearsal"]).text.contains("MBB322"), "list_transcripts can filter by folder")
        check(call(server, "list_transcripts", ["limit": 1]).text.components(separatedBy: "\"name\"").count == 2, "list_transcripts honors limit")
        let read = call(server, "read_transcript", ["folder": "MBB322", "name": "2026-10-23"])
        check(!read.isError && read.text.contains("The Citric Acid cycle") && read.text.contains("Summary (2026-10-23 summary.md)")
              && read.text.contains("Summary text here."), "read_transcript returns the text and its summary")
        check(call(server, "read_transcript", ["folder": "MBB322", "name": "2026-10-23.md"]).text.contains("Citric"),
              "read_transcript accepts a name with the .md suffix")
        let hit = call(server, "search_transcripts", ["query": "CITRIC acid"])
        check(!hit.isError && hit.text.contains("The Citric Acid cycle makes NADH.") && hit.text.contains("\"line\":9"),
              "search_transcripts ignores case and reports the line")
        check(call(server, "search_transcripts", ["query": "cafe"]).text.contains("café"), "search_transcripts ignores accents")
        check(call(server, "search_transcripts", ["query": "e", "limit": 2]).text.components(separatedBy: "\"line\"").count == 3,
              "search_transcripts honors limit")
        check(!folders.text.contains("Random Documents") && !all.text.contains("HANDOFF") && !all.text.contains("codex_prompt"),
              "only Nosy transcripts are listed, never other markdown in the folder")
        check(call(server, "read_transcript", ["folder": "MBB322", "name": "HANDOFF"]).isError, "unrelated markdown cannot be read")
        check(!call(server, "search_transcripts", ["query": "clinic"]).text.contains("HANDOFF")
              && !call(server, "search_transcripts", ["query": "ATP"]).text.contains("codex"), "unrelated markdown is never searched")
        check(call(server, "search_transcripts", ["query": "qqxzzy"]).text == "[]", "search_transcripts returns an empty list when nothing matches")
        check(call(server, "search_transcripts", ["query": "   "]).isError, "an empty search is refused")
        check(call(server, "search_transcripts", ["query": String(repeating: "a", count: 201)]).isError, "an overlong search is refused")
        check(call(server, "search_transcripts", [:]).isError, "a missing query is refused")
        check(call(server, "list_transcripts", ["folder": 3]).isError, "a folder that is not text is refused")

        // Path safety: nothing outside the transcripts folder is ever read
        let refused: [(String, [String: Any])] = [
            ("read_transcript", ["folder": "../transcripts", "name": "2026-10-23"]),
            ("read_transcript", ["folder": "MBB322/..", "name": "2026-10-23"]),
            ("read_transcript", ["folder": "MBB322", "name": "../../outside/secret"]),
            ("read_transcript", ["folder": "MBB322", "name": "leak"]),
            ("read_transcript", ["folder": "Escape", "name": "secret"]),
            ("read_transcript", ["folder": "MBB322", "name": ".hidden"]),
            ("read_transcript", ["folder": "MBB322", "name": ""]),
            ("read_transcript", ["folder": "MBB\\322", "name": "2026-10-23"]),
            ("list_transcripts", ["folder": "Escape"]),
            ("list_transcripts", ["folder": "/etc"]),
            ("read_transcript", ["folder": "Hidden", "name": "x"]),
        ]
        for (tool, arguments) in refused {
            let result = call(server, tool, arguments)
            check(result.isError && !result.text.contains("TOP SECRET"), "\(tool) refuses \(arguments)")
        }
        var rejectedSlash = false
        do { _ = try TranscriptStore.component("a/b", kind: "folder") } catch { rejectedSlash = true }
        check(rejectedSlash, "names with a slash are not components")

        // Transcripts folder precedence: environment, then the stored Settings folder, then the defaults
        check(TranscriptRoot.resolve(environment: ["NOSY_TRANSCRIPTS_DIR": "/env"], stored: "/stored").path == "/env", "the environment override wins")
        check(TranscriptRoot.resolve(environment: [:], stored: "/stored").path == "/stored", "the stored folder comes next")
        check(TranscriptRoot.resolve(environment: [:], stored: nil, home: root.appendingPathComponent("home")).path.hasSuffix("Documents/Nosy"),
              "the default folder is Documents/Nosy")

        // Claude Desktop config merge
        let helper = "/Applications/Nosy.app/Contents/Helpers/nosy-mcp"
        let fresh = try ClaudeDesktopConfig.adding(to: nil, command: helper) ?? Data()
        check(try ClaudeDesktopConfig.isAdded(fresh), "adding to a missing config creates the entry")
        check(dict(dict(try parse(fresh)["mcpServers"])["nosy"])["command"] as? String == helper, "the entry runs the bundled helper")
        check(try ClaudeDesktopConfig.adding(to: fresh, command: helper) == nil, "adding twice changes nothing")
        let existing = Data(#"{"theme":"dark","mcpServers":{"other":{"command":"/bin/other"}},"nested":{"keep":[1,2]}}"#.utf8)
        let merged = try parse(try ClaudeDesktopConfig.adding(to: existing, command: helper) ?? Data())
        check(merged["theme"] as? String == "dark" && dict(dict(merged["mcpServers"])["other"])["command"] as? String == "/bin/other",
              "adding keeps other keys and other servers")
        check(dict(merged["nested"])["keep"] as? [Int] == [1, 2], "adding keeps nested values")
        let removed = try parse(try ClaudeDesktopConfig.removing(from: try ClaudeDesktopConfig.adding(to: existing, command: helper)) ?? Data())
        check(removed["theme"] as? String == "dark" && dict(removed["mcpServers"])["nosy"] == nil
              && dict(dict(removed["mcpServers"])["other"])["command"] as? String == "/bin/other", "removing only drops the nosy entry")
        check(try ClaudeDesktopConfig.removing(from: existing) == nil, "removing when absent changes nothing")
        check(try ClaudeDesktopConfig.adding(to: Data(" \n".utf8), command: helper) != nil, "a blank file counts as an empty config")
        var refusedMerge = false
        do { _ = try ClaudeDesktopConfig.adding(to: Data("{broken".utf8), command: helper) } catch { refusedMerge = true }
        check(refusedMerge, "invalid JSON is refused rather than replaced")
        refusedMerge = false
        do { _ = try ClaudeDesktopConfig.adding(to: Data(#"{"mcpServers":[1]}"#.utf8), command: helper) } catch { refusedMerge = true }
        check(refusedMerge, "a non object mcpServers is refused")
        let setup = ClaudeDesktopConfig.setupText(command: helper)
        check(setup.contains("claude mcp add nosy -- \(helper)") && setup.contains("\"command\" : \"\(helper)\""), "setup text has both snippets")
        check(ClaudeDesktopConfig.shellQuoted("/Users/a b/nosy-mcp") == "'/Users/a b/nosy-mcp'", "paths with spaces are quoted for the shell")

        // Files on disk: backups, status, and the helper check
        let configURL = root.appendingPathComponent("Claude/claude_desktop_config.json")
        let helperURL = root.appendingPathComponent("Helper/nosy-mcp")
        let connector = ClaudeConnector(configURL: configURL, helperURL: helperURL)
        var missingHelper = false
        do { try connector.add() } catch { missingHelper = true }
        check(missingHelper && !manager.fileExists(atPath: configURL.path), "add refuses when the helper is missing and writes nothing")
        try manager.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        manager.createFile(atPath: helperURL.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        check(connector.status() == .notAdded, "a missing config reads as not installed")
        try connector.add()
        check(connector.status() == .added, "add creates the config and reports added")
        try manager.removeItem(at: configURL)
        try manager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try existing.write(to: configURL)
        try connector.add()
        let backups = try manager.contentsOfDirectory(atPath: configURL.deletingLastPathComponent().path).filter { $0.contains(".backup-") }
        check(backups.count == 1, "add backs up the original config first")
        let backupData = try Data(contentsOf: configURL.deletingLastPathComponent().appendingPathComponent(backups[0]))
        check(backupData == existing, "the backup holds the original bytes")
        check(dict(dict(try parse(Data(contentsOf: configURL)))["mcpServers"])["other"] != nil, "the written config keeps other servers")
        try connector.remove()
        check(connector.status() == .notAdded, "remove reports not installed")
        try Data("{broken".utf8).write(to: configURL)
        if case .unreadable = connector.status() {} else { fatalError("FAIL: broken config is reported, not overwritten") }
        var refusedWrite = false
        do { try connector.add() } catch { refusedWrite = true }
        let stillBroken = try Data(contentsOf: configURL)
        check(refusedWrite && stillBroken == Data("{broken".utf8), "add leaves a broken config untouched")

        print("CONNECTOR TESTS PASS: \(assertions) assertions")
    }

    // MARK: Fixtures

    static func makeFixtures(transcripts: URL, outside: URL) throws {
        let manager = FileManager.default
        let mbb = transcripts.appendingPathComponent("MBB322", isDirectory: true)
        let rehearsal = transcripts.appendingPathComponent("Rehearsal", isDirectory: true)
        let hidden = transcripts.appendingPathComponent(".Hidden", isDirectory: true)
        for folder in [mbb, rehearsal, hidden, outside] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try """
        # MBB322 — 2026-10-23

        - Date: 2026-10-23
        - Started: 16:13
        - Length: 1 min

        ## Transcript

        The Citric Acid cycle makes NADH.
        ATP synthase is key. A café example follows.
        """.write(to: mbb.appendingPathComponent("2026-10-23.md"), atomically: true, encoding: .utf8)
        try "Summary text here.\n".write(to: mbb.appendingPathComponent("2026-10-23 summary.md"), atomically: true, encoding: .utf8)
        try """
        # Rehearsal — 2026-10-20

        - Date: 2026-10-20
        - Started: 09:00
        - Length: 2 min

        ## Transcript

        Rehearsal notes about ATP.
        """.write(to: rehearsal.appendingPathComponent("2026-10-20.md"), atomically: true, encoding: .utf8)
        try "hidden\n".write(to: mbb.appendingPathComponent(".2026-10-24.md.tmp"), atomically: true, encoding: .utf8)
        try "not a transcript\n".write(to: mbb.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        // A destination like ~/Downloads holds the owner's own markdown; it must never be exposed.
        try "# HANDOFF\n\nATP plan for the clinic.\n".write(to: mbb.appendingPathComponent("HANDOFF.md"), atomically: true, encoding: .utf8)
        let unrelated = transcripts.appendingPathComponent("Random Documents", isDirectory: true)
        try manager.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try "# codex prompt\n\nATP.\n".write(to: unrelated.appendingPathComponent("codex_prompt.md"), atomically: true, encoding: .utf8)
        try "hidden folder\n".write(to: hidden.appendingPathComponent("x.md"), atomically: true, encoding: .utf8)
        let secret = outside.appendingPathComponent("secret.md")
        try "TOP SECRET\n".write(to: secret, atomically: true, encoding: .utf8)
        try "secret summary\n".write(to: outside.appendingPathComponent("secret summary.md"), atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(at: mbb.appendingPathComponent("leak.md"), withDestinationURL: secret)
        try manager.createSymbolicLink(at: transcripts.appendingPathComponent("Escape", isDirectory: true), withDestinationURL: outside)
    }

    // MARK: Helpers

    static func rpc(_ id: Int, _ method: String, _ params: [String: Any]) -> String {
        json(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    static func json(_ value: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    static func object(_ text: String?) -> [String: Any] {
        guard let text, let value = (try? parse(Data(text.utf8))) else { return [:] }
        return value
    }

    static func parse(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.wrongType("root")
        }
        return value
    }

    static func batchReplies(_ text: String?) -> [Any] {
        guard let text, let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any] else { return [] }
        return value
    }

    static func dict(_ value: Any?) -> [String: Any] {
        (value as? [String: Any]) ?? [:]
    }

    static func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any]) -> (text: String, isError: Bool) {
        let reply = object(server.respond(to: rpc(100, "tools/call", ["name": name, "arguments": arguments])))
        let result = dict(reply["result"])
        let content = (result["content"] as? [[String: Any]]) ?? []
        return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), result["isError"] as? Bool ?? true)
    }
}
