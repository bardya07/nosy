import Foundation

// Bound a client's input before JSON parsing; resume at the next newline after a bad frame.
struct MCPLineBuffer {
    static let maxBytes = 1_048_576
    private var pending = Data()
    private var oversized = false
    mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A {
                lines.append(finishLine())
            } else if !oversized {
                if pending.count < Self.maxBytes { pending.append(byte) }
                else { pending.removeAll(keepingCapacity: true); oversized = true }
            }
        }
        return lines
    }
    mutating func finish() -> String? {
        guard oversized || !pending.isEmpty else { return nil }
        return finishLine()
    }
    private mutating func finishLine() -> String {
        let line = oversized ? "\u{0}" : String(data: pending, encoding: .utf8) ?? "\u{0}"
        pending.removeAll(keepingCapacity: true)
        oversized = false
        return line
    }
}

// A small Model Context Protocol server: JSON-RPC 2.0, one message per line, tools only, read only.
// It never writes to the transcripts folder.
struct MCPServer: Sendable {
    static let serverName = "nosy"
    static let serverVersion = "1.0"
    static let latestProtocolVersion = "2025-11-25"
    static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let instructions = "Read only access to the transcripts Nosy saved from the user's lectures. Start with list_folders, or use search_transcripts to find a topic."

    let store: TranscriptStore

    // The reply for one input line, or nil when the message needs none (a notification or a blank line).
    func respond(to line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let message = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            return Self.encode(Self.failure(id: NSNull(), code: -32700, message: "Parse error"))
        }
        if let batch = message as? [Any] {
            guard !batch.isEmpty else {
                return Self.encode(Self.failure(id: NSNull(), code: -32600, message: "Invalid Request"))
            }
            let replies = batch.compactMap { handle($0) }
            return replies.isEmpty ? nil : Self.encode(replies)
        }
        return handle(message).flatMap { Self.encode($0) }
    }

    // MARK: Dispatch

    private func handle(_ message: Any) -> [String: Any]? {
        guard let request = message as? [String: Any] else {
            return Self.failure(id: NSNull(), code: -32600, message: "Invalid Request")
        }
        let id = request["id"]
        if let id, !(id is NSNull), !(id is String),
           (!(id is NSNumber) || CFGetTypeID(id as CFTypeRef) == CFBooleanGetTypeID()) {
            return Self.failure(id: NSNull(), code: -32600, message: "Invalid Request")
        }
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            return Self.failure(id: id ?? NSNull(), code: -32600, message: "Invalid Request")
        }
        // Notifications carry no id and get no reply.
        guard let id else { return nil }
        if let params = request["params"], !(params is [String: Any]) {
            return Self.failure(id: id, code: -32602, message: "Parameters must be an object.")
        }
        let params = request["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return Self.success(id: id, result: initialize(params))
        case "ping":
            return Self.success(id: id, result: [String: Any]())
        case "tools/list":
            return Self.success(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            return toolCall(id: id, params: params)
        default:
            return Self.failure(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initialize(_ params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        // Speak the version the client asked for when we know it; otherwise offer our latest.
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.latestProtocolVersion
        return [
            "protocolVersion": version,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": Self.serverName, "title": "Nosy", "version": Self.serverVersion],
            "instructions": Self.instructions,
        ]
    }

    private func toolCall(id: Any, params: [String: Any]) -> [String: Any] {
        guard let name = params["name"] as? String else {
            return Self.failure(id: id, code: -32602, message: "Missing tool name.")
        }
        guard Self.toolNames.contains(name) else {
            return Self.failure(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
        if let arguments = params["arguments"], !(arguments is [String: Any]) {
            return Self.failure(id: id, code: -32602, message: "Arguments must be an object.")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            let text = try callTool(name, arguments)
            return Self.success(id: id, result: ["content": [Self.textBlock(text)], "isError": false])
        } catch {
            // Tool problems are reported as a tool result the model can read, not as a protocol error.
            return Self.success(id: id, result: ["content": [Self.textBlock(error.localizedDescription)], "isError": true])
        }
    }

    private func callTool(_ name: String, _ arguments: [String: Any]) throws -> String {
        switch name {
        case "list_folders":
            return try Self.json(store.folders())
        case "list_transcripts":
            let folder = try optionalString(arguments, "folder")
            let limit = integer(arguments, "limit", default: 50, in: 1...200)
            return try Self.json(store.transcripts(folder: folder, limit: limit))
        case "read_transcript":
            let document = try store.read(folder: try requiredString(arguments, "folder"),
                                          name: try requiredString(arguments, "name"))
            guard let summary = document.summary else { return document.text }
            return document.text + "\n\n---\n\nSummary (\(document.name) summary.md):\n\n" + summary
        case "search_transcripts":
            let query = try requiredString(arguments, "query")
            let limit = integer(arguments, "limit", default: 20, in: 1...100)
            return try Self.json(store.search(query: query, limit: limit))
        default:
            throw ToolError.unknownTool(name)
        }
    }

    // MARK: Arguments

    private func requiredString(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = arguments[key] as? String else { throw ToolError.missing(key) }
        return value
    }

    private func optionalString(_ arguments: [String: Any], _ key: String) throws -> String? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw ToolError.wrongType(key) }
        return text
    }

    // Accepts a number or a numeric string, and clamps to the allowed range.
    private func integer(_ arguments: [String: Any], _ key: String, default fallback: Int, in range: ClosedRange<Int>) -> Int {
        let value = (arguments[key] as? Int) ?? (arguments[key] as? String).flatMap { Int($0) } ?? fallback
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: Tool catalogue

    static var toolNames: [String] { ["list_folders", "list_transcripts", "read_transcript", "search_transcripts"] }

    static var toolDefinitions: [[String: Any]] {
        [
            tool("list_folders", title: "List transcript folders",
                 description: "List the folders of Nosy transcripts, with how many transcripts each one holds.",
                 properties: [:]),
            tool("list_transcripts", title: "List transcripts",
                 description: "List saved transcripts, newest first, with folder, name, date, duration and file path. Pass a folder to list only that one. Pass folder and name to read_transcript.",
                 properties: [
                    "folder": ["type": "string", "description": "Folder name, as returned by list_folders."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "How many to return. Defaults to 50."],
                 ]),
            tool("read_transcript", title: "Read a transcript",
                 description: "Read the full text of one transcript. Includes its summary when one has been saved.",
                 properties: [
                    "folder": ["type": "string", "description": "Folder name, as returned by list_folders."],
                    "name": ["type": "string", "description": "Transcript name, as returned by list_transcripts."],
                 ],
                 required: ["folder", "name"]),
            tool("search_transcripts", title: "Search transcripts",
                 description: "Search every transcript for a word or phrase. Returns matching lines, newest transcript first. Case and accents are ignored.",
                 properties: [
                    "query": ["type": "string", "description": "The word or phrase to find."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "How many matching lines to return. Defaults to 20."],
                 ],
                 required: ["query"]),
        ]
    }

    private static func tool(_ name: String, title: String, description: String,
                             properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": schema,
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ]
    }

    // MARK: Encoding

    private static func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    private static func json<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func success(id: Any, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func failure(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    // One compact line of JSON, with no raw newlines, as stdio transport requires.
    static func encode(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

enum ToolError: LocalizedError, Equatable {
    case missing(String)
    case wrongType(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .missing(let key): "Missing the \"\(key)\" argument."
        case .wrongType(let key): "The \"\(key)\" argument must be text."
        case .unknownTool(let name): "Unknown tool: \(name)"
        }
    }
}
