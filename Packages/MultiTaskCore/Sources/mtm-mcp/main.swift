import Foundation
import MultiTaskCore

/// `mtm-mcp` — the board, spoken over the Model Context Protocol.
///
/// Point a Claude Code (or any MCP client) config at this binary and an agent
/// can read the board, take the next task, and file work it discovered
/// elsewhere. That is what makes the North Star reachable: an agent with Notion
/// and Linear also connected does the integrating, and this app holds the board.
///
/// Transport is JSON-RPC 2.0 over stdio, newline-delimited — the same framing
/// the daemon protocol uses, so `FrameReader` handles the partial reads.
struct MCPStdioServer {
    let server: MCPServer
    let codec = MessageCodec()

    /// stderr, because stdout is the protocol channel — anything printed there
    /// corrupts a message and the client sees a parse error rather than a log.
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[mtm-mcp] \(message)\n".utf8))
    }

    func run() async {
        // Line-buffered so a reply reaches the client as soon as it's written,
        // rather than sitting in a block buffer until the next one fills it.
        setvbuf(stdout, nil, _IOLBF, 0)

        var reader = FrameReader()
        let input = FileHandle.standardInput

        Self.log("ready — \(MCPServer.tools.count) tools")

        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }        // EOF: the client went away.

            let batch = reader.append(chunk)
            if batch.oversizedDropped > 0 {
                Self.log("dropped \(batch.oversizedDropped) oversized message(s)")
            }
            for frame in batch.frames {
                if let reply = await handle(frame) {
                    FileHandle.standardOutput.write(FrameWriter.frame(reply))
                }
            }
        }
    }

    /// - Returns: the reply, or `nil` for a notification, which by JSON-RPC rule
    ///   gets no response at all. Replying to one is a protocol error that some
    ///   clients treat as fatal.
    func handle(_ frame: Data) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            return error(id: nil, code: -32700, message: "Parse error")
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return error(id: id, code: -32600, message: "No method")
        }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return result(id: id, [
                "protocolVersion": MCPServer.protocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": MCPServer.serverName, "version": "1.0.0"]
            ])

        case "notifications/initialized", "initialized":
            return nil

        case "ping":
            return result(id: id, [:])

        case "tools/list":
            return result(id: id, [
                "tools": MCPServer.tools.map { tool in
                    ["name": tool.name,
                     "description": tool.description,
                     "inputSchema": tool.schema] as [String: Any]
                }
            ])

        case "tools/call":
            guard let name = params["name"] as? String else {
                return error(id: id, code: -32602, message: "No tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = await server.call(tool: name, arguments: arguments)
            return result(id: id, [
                "content": [["type": "text", "text": text]],
                "isError": isError
            ])

        default:
            // Unknown notifications are ignored; unknown requests get an error.
            if id == nil { return nil }
            return error(id: id, code: -32601, message: "No method \(method)")
        }
    }

    // MARK: JSON-RPC envelopes

    func result(id: Any?, _ payload: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": payload])
    }

    func error(id: Any?, code: Int, message: String) -> Data {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(),
                "error": ["code": code, "message": message]])
    }

    func encode(_ object: [String: Any]) -> Data {
        // No pretty printing: a newline inside a message would split the frame.
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

// The engine runs in-process here, exactly as it does for `mtm`. When the daemon
// exists this becomes a socket client and no tool changes.
let engine = InProcessEngine(configuration: StaticConfiguration(Configuration()))
let server = MCPServer(client: engine, origin: "mcp")
await MCPStdioServer(server: server).run()
