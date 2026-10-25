import Foundation
import Darwin

// Entry point for the nosy-mcp helper that Claude Desktop, Claude Code and other MCP clients launch.
// It reads JSON-RPC messages from stdin, one per line, and writes replies to stdout. Nothing else goes to stdout.
@main
enum NosyMCPMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        func respond(_ line: String) -> Bool {
            // Resolved for each message, so a folder change in Settings applies without restarting the helper.
            let server = MCPServer(store: TranscriptStore(root: TranscriptRoot.resolve()))
            guard let reply = server.respond(to: line) else { return true }
            do { try FileHandle.standardOutput.write(contentsOf: Data((reply + "\n").utf8)); return true }
            catch { return false } // A disconnected client is a normal shutdown.
        }
        var framing = MCPLineBuffer()
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0 { if errno == EINTR { continue }; return }
            if count == 0 { break }
            for line in framing.append(Data(bytes.prefix(count))) { if !respond(line) { return } }
        }
        if let final = framing.finish() { _ = respond(final) }
    }
}
