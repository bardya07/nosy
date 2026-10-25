import Foundation

// Entry point for the nosy-mcp helper that Claude Desktop, Claude Code and other MCP clients launch.
// It reads JSON-RPC messages from stdin, one per line, and writes replies to stdout. Nothing else goes to stdout.
@main
enum NosyMCPMain {
    static func main() {
        while let line = readLine(strippingNewline: true) {
            // Resolved for each message, so a folder change in Settings applies without restarting the helper.
            let server = MCPServer(store: TranscriptStore(root: TranscriptRoot.resolve()))
            guard let reply = server.respond(to: line) else { continue }
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }
}
