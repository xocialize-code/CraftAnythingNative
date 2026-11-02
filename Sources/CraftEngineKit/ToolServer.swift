import Foundation
import os

/// A tool the host answers itself, under the engine's own tool id.
public protocol NativeTool: Sendable {
    var name: String { get }
    /// One line for `tools/list`.
    var description: String { get }
    /// The `tools/call` result: `content`, and `structuredContent` / `isError` as the engine sends
    /// them. `meta` is the request's `_meta` (the engine sends `clean_room` with a replaced tool).
    func call(_ arguments: JSONValue, meta: JSONValue) async -> JSONValue
}

extension NativeTool {
    public var description: String { "" }
}

/// An MCP server on stdio that stands in front of the pinned engine (`craft-anything-cli mcp …`).
/// Every line passes through unchanged, both ways, except a `tools/call` for a tool in `native`,
/// which is answered here (and its `notifications/cancelled` with it). The engine starts agents
/// with this as their tool server when `CRAFT_ANYTHING_TOOL_SERVER` names it.
public final class ToolServer: Sendable {
    public typealias Log = @Sendable (String) -> Void

    private let engine: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let native: [String: any NativeTool]
    private let log: Log
    private let running = OSAllocatedUnfairLock(initialState: [String: Task<Void, Never>]())

    public init(engine: URL, arguments: [String], environment: [String: String], native: [any NativeTool] = [], log: @escaping Log = { _ in }) {
        self.engine = engine
        self.arguments = arguments
        self.environment = environment
        self.native = Dictionary(native.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.log = log
    }

    /// Serve `input` → engine → `output` until the engine exits; returns its exit status. When
    /// `input` ends the engine's stdin is closed, so it finishes what it's doing and exits.
    /// `forwardSignals` passes SIGTERM and SIGINT on to the engine instead of dying of them; it
    /// changes the whole process, so only the server's own program sets it.
    public func run(input: FileHandle, output: FileHandle, errors: FileHandle = .standardError, forwardSignals: Bool = false) async throws -> Int32 {
        let process = Process()
        process.executableURL = engine
        process.arguments = arguments
        process.environment = environment
        let toEngine = Pipe(), fromEngine = Pipe()
        process.standardInput = toEngine
        process.standardOutput = fromEngine
        process.standardError = errors
        let exited = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { p in
            exited.continuation.yield(p.terminationStatus)
            exited.continuation.finish()
        }
        try process.run()
        log("engine \(process.processIdentifier) started")
        let out = LineWriter(output)
        let engineIn = LineWriter(toEngine.fileHandleForWriting)

        let replies = Task {
            for await line in LineSplitter.stream(from: fromEngine.fileHandleForReading) { await out.write(line) }
        }
        let requests = Task {
            for await line in LineSplitter.stream(from: input) {
                if !(await self.answer(line, out: out)) { await engineIn.write(line) }
            }
            await engineIn.close()
        }
        let signals = forwardSignals ? Self.forward(signals: [SIGTERM, SIGINT], to: process) : []
        var status: Int32 = 0
        for await s in exited.stream { status = s }
        signals.forEach { $0.cancel() }
        await replies.value
        requests.cancel()
        running.withLock { $0.values.forEach { $0.cancel() } }
        log("engine exited \(status)")
        return status
    }

    /// Answer `line` here when it's a call to a native tool or cancels one; false to pass it on.
    private func answer(_ line: String, out: LineWriter) async -> Bool {
        guard line.contains("tools/call") || line.contains("notifications/cancelled"), let msg = JSONValue.parse(line) else { return false }
        let id = msg["id"] ?? .null
        switch msg["method"]?.string {
        case "tools/call":
            let name = msg["params"]?["name"]?.string ?? ""
            guard let tool = native[name] else {
                log("call \(name)")
                return false
            }
            log("call \(name) (native)")
            let key = id.compact()
            let task = Task {
                let result = await tool.call(msg["params"]?["arguments"] ?? [:], meta: msg["params"]?["_meta"] ?? .null)
                // A cancelled request gets no reply.
                guard running.withLock({ $0.removeValue(forKey: key) }) != nil, !Task.isCancelled else { return }
                await out.write(JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).compact())
            }
            running.withLock { $0[key] = task }
            return true
        case "notifications/cancelled":
            let key = (msg["params"]?["requestId"] ?? .null).compact()
            guard let task = running.withLock({ $0.removeValue(forKey: key) }) else { return false }
            task.cancel()
            return true
        default:
            return false
        }
    }
}

/// Writes whole lines to a handle, one at a time.
actor LineWriter {
    private let handle: FileHandle
    private var closed = false

    init(_ handle: FileHandle) { self.handle = handle }

    func write(_ line: String) {
        guard !closed else { return }
        var data = Data(line.utf8)
        data.append(0x0A)
        do { try handle.write(contentsOf: data) } catch { closed = true }
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}

extension ToolServer {
    /// Pass these signals on to `process` instead of dying of them: the engine takes a first
    /// SIGTERM as Ctrl-C and a second as "leave now", so the agent stopping this server stops it
    /// the same way.
    static func forward(signals: [Int32], to process: Process) -> [DispatchSourceSignal] {
        signals.map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { if process.isRunning { kill(process.processIdentifier, sig) } }
            source.resume()
            return source
        }
    }
}
