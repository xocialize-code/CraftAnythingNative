import Foundation
import os

/// An MCP server on stdio that answers only native tools: the engine starts it as a plugin
/// (`[[plugins.mcp]]` with `replaces`) and calls its tools under the engine's own ids. Requests
/// run concurrently; `notifications/cancelled` cancels one, and a cancelled request gets no reply.
public final class MCPServer: Sendable {
    public typealias Log = ToolServer.Log

    private let name: String
    private let version: String
    private let tools: [String: any NativeTool]
    private let order: [String]
    private let log: Log
    private let running = OSAllocatedUnfairLock(initialState: [String: Task<Void, Never>]())

    public init(name: String, version: String, tools: [any NativeTool], log: @escaping Log = { _ in }) {
        self.name = name
        self.version = version
        self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.order = tools.map(\.name)
        self.log = log
    }

    /// Answer `input` on `output` until `input` ends; requests still running are cancelled then.
    public func run(input: FileHandle, output: FileHandle) async {
        let out = LineWriter(output)
        for await line in LineSplitter.stream(from: input) {
            guard let msg = JSONValue.parse(line) else { continue }
            await handle(msg, out: out)
        }
        running.withLock { $0.values.forEach { $0.cancel() } }
    }

    private func handle(_ msg: JSONValue, out: LineWriter) async {
        let id = msg["id"]
        let reply: @Sendable (JSONValue) async -> Void = { result in
            guard let id else { return }
            await out.write(JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).compact())
        }
        switch msg["method"]?.string {
        case "initialize":
            let asked = msg["params"]?["protocolVersion"]?.string ?? "2025-06-18"
            await reply(["protocolVersion": .string(asked), "capabilities": ["tools": [:]], "serverInfo": ["name": .string(name), "version": .string(version)]])
        case "ping":
            await reply([:])
        case "tools/list":
            let list = order.compactMap { tools[$0] }.map { t -> JSONValue in
                ["name": .string(t.name), "description": .string(t.description), "inputSchema": ["type": "object"]]
            }
            await reply(["tools": .array(list)])
        case "tools/call":
            let toolName = msg["params"]?["name"]?.string ?? ""
            guard let tool = tools[toolName], let id else {
                if let id {
                    await out.write(JSONValue.object(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": .string("No tool named \(toolName)")]]).compact())
                }
                return
            }
            log("call \(toolName)")
            let key = id.compact()
            let task = Task {
                let result = await tool.call(msg["params"]?["arguments"] ?? [:], meta: msg["params"]?["_meta"] ?? .null)
                guard running.withLock({ $0.removeValue(forKey: key) }) != nil, !Task.isCancelled else { return }
                await reply(result)
            }
            running.withLock { $0[key] = task }
        case "notifications/cancelled":
            let key = (msg["params"]?["requestId"] ?? .null).compact()
            running.withLock { $0.removeValue(forKey: key) }?.cancel()
        case .some(let method) where id != nil && !method.hasPrefix("notifications/"):
            await out.write(JSONValue.object(["jsonrpc": "2.0", "id": id ?? .null, "error": ["code": -32601, "message": .string("No method \(method)")]]).compact())
        default:
            break
        }
    }
}
