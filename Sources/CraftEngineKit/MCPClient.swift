import Foundation
import os

/// A failure talking to the engine: a JSON-RPC error, a timeout, or the engine stopping.
public struct EngineError: Error, Sendable, LocalizedError, Equatable {
    public var code: Int?
    public var message: String

    public init(code: Int? = nil, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Something the engine said on its own, outside a reply.
public enum EngineEvent: Sendable {
    /// A JSON-RPC notification (`notifications/progress`, `notifications/tools/list_changed`, …).
    case notification(method: String, params: JSONValue)
    /// The engine process ended, with the last lines it printed on stderr.
    case exited(status: Int32, stderr: String)
}

/// A client for the engine's MCP server: `craft-anything-cli mcp`, newline-delimited JSON-RPC 2.0
/// over the child's stdin and stdout. Requests may overlap; each one gets its own id and waits for
/// its own reply. stderr is drained so the pipe never fills, and its last lines are kept for errors.
public actor MCPClient {
    public nonisolated let events: AsyncStream<EngineEvent>
    private let eventSink: AsyncStream<EngineEvent>.Continuation

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let stderrTail = TextTail(limit: 40)
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var reader: Task<Void, Never>?
    private var finished: EngineError?

    /// - Parameters:
    ///   - executable: the pinned craft-anything-cli, under its own name (it finds itself by name to
    ///     start a builder's tools).
    ///   - environment: the child's environment; nil for this process's own.
    public init(executable: URL, arguments: [String], environment: [String: String]? = nil) {
        (events, eventSink) = AsyncStream.makeStream(of: EngineEvent.self)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    /// Start the engine. Throws when the program can't be started.
    public func start() throws {
        let lines = LineSplitter.stream(from: output.fileHandleForReading)
        let tail = stderrTail
        errors.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { tail.append(d) }
        }
        let sink = eventSink
        process.terminationHandler = { p in
            // Give the readers a moment to take the last lines first.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                sink.yield(.exited(status: p.terminationStatus, stderr: tail.text))
            }
        }
        do {
            try process.run()
        } catch {
            throw EngineError("Couldn't start the engine at \(process.executableURL?.path ?? "?"): \(error.localizedDescription)")
        }
        reader = Task { [weak self] in
            for await line in lines {
                await self?.receive(line)
            }
            await self?.endOfOutput()
        }
    }

    /// The MCP handshake: `initialize`, then `notifications/initialized`. Returns the server's reply
    /// (`serverInfo`, `instructions`, `capabilities`).
    public func initialize(clientName: String, version: String) async throws -> JSONValue {
        let params: JSONValue = [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": .string(clientName), "version": .string(version)],
        ]
        let reply = try await request("initialize", params, timeout: .seconds(60))
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return reply
    }

    /// Every tool the server lists, across pages.
    public func listTools() async throws -> [EngineTool] {
        var tools: [EngineTool] = []
        var cursor: String?
        repeat {
            let params: JSONValue = cursor.map { ["cursor": .string($0)] } ?? [:]
            let page = try await request("tools/list", params, timeout: .seconds(60))
            tools += (page["tools"]?.array ?? []).compactMap(EngineTool.init(json:))
            cursor = page["nextCursor"]?.string
        } while cursor != nil
        return tools
    }

    /// Run a tool. A tool that fails comes back as a result with `isError`, not as a throw; throws
    /// only when the call itself couldn't be made or answered in time.
    public func callTool(_ name: String, _ arguments: JSONValue = [:], timeout: Duration = .seconds(120)) async throws -> ToolResult {
        let reply = try await request("tools/call", ["name": .string(name), "arguments": arguments], timeout: timeout)
        return ToolResult(json: reply)
    }

    /// Read an `evidence://` or `investigation://` resource as text.
    public func readResource(_ uri: String) async throws -> String {
        let reply = try await request("resources/read", ["uri": .string(uri)], timeout: .seconds(60))
        return (reply["contents"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
    }

    /// Send a request and wait for its reply's `result`. On a timeout, or when the calling task is
    /// cancelled, the server is told to cancel.
    public func request(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        if let finished { throw finished }
        try Task.checkCancellation()
        let id = nextID
        nextID += 1
        let message: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                pending[id] = cont
                do {
                    try send(message)
                } catch {
                    pending[id] = nil
                    cont.resume(throwing: error)
                    return
                }
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.expire(id, reason: "timeout", EngineError("The engine didn't answer \(method) in time."))
                }
            }
        } onCancel: {
            // Runs after the body has registered the request: it waits for the actor.
            Task { await self.expire(id, reason: "cancelled", CancellationError()) }
        }
    }

    /// Stop the engine: close its stdin (it finishes running calls and exits), then signal it if it
    /// is still there after `grace`. The CLI takes a first SIGTERM as Ctrl-C, which only raises a
    /// flag that a waiting call may not look at; a second one makes it leave. SIGKILL is last.
    public func stop(grace: Duration = .seconds(3)) async {
        try? input.fileHandleForWriting.close()
        if await exited(within: grace) { return fail(EngineError("The engine was stopped.")) }
        for _ in 0..<2 where process.isRunning {
            process.terminate()
            if await exited(within: .milliseconds(500)) { break }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = await exited(within: .seconds(1))
        }
        fail(EngineError("The engine was stopped."))
    }

    private func exited(within wait: Duration) async -> Bool {
        let deadline = ContinuousClock.now + wait
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !process.isRunning
    }

    public var isRunning: Bool { process.isRunning }

    /// The last lines the engine printed on stderr.
    public nonisolated var stderr: String { stderrTail.text }

    // MARK: - Wire

    private func send(_ message: JSONValue) throws {
        if let finished { throw finished }
        var data = Data(message.compact().utf8)
        data.append(0x0A)
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw EngineError("Couldn't write to the engine: \(error.localizedDescription)")
        }
    }

    private func receive(_ line: String) {
        guard let msg = JSONValue.parse(line) else { return }
        if let id = msg["id"]?.int, msg["method"] == nil {
            guard let cont = pending.removeValue(forKey: id) else { return }
            if let err = msg["error"] {
                cont.resume(throwing: EngineError(code: err["code"]?.int, err["message"]?.string ?? "The engine refused the request."))
            } else {
                cont.resume(returning: msg["result"] ?? .null)
            }
        } else if let method = msg["method"]?.string {
            if msg["id"] != nil {
                // The server asking us something (roots, sampling): we offer none of it.
                try? send(["jsonrpc": "2.0", "id": msg["id"] ?? .null, "error": ["code": -32601, "message": "Not supported by this client"]])
            } else {
                eventSink.yield(.notification(method: method, params: msg["params"] ?? .null))
            }
        }
    }

    private func expire(_ id: Int, reason: String, _ error: any Error) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        try? send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": .number(Double(id)), "reason": .string(reason)]])
        cont.resume(throwing: error)
    }

    private func endOfOutput() {
        let tail = stderrTail.text.trimmingCharacters(in: .whitespacesAndNewlines)
        fail(EngineError(tail.isEmpty ? "The engine stopped." : "The engine stopped: \(tail)"))
    }

    private func fail(_ error: EngineError) {
        if finished == nil { finished = error }
        let waiting = pending
        pending.removeAll()
        for (_, cont) in waiting { cont.resume(throwing: error) }
    }
}

/// Splits a pipe's bytes into lines, in order, on the pipe's own queue.
enum LineSplitter {
    static func stream(from handle: FileHandle) -> AsyncStream<String> {
        let (stream, sink) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        let buffer = OSAllocatedUnfairLock(initialState: Data())
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                let rest = buffer.withLock { b in defer { b.removeAll() }; return b }
                if !rest.isEmpty { sink.yield(String(decoding: rest, as: UTF8.self)) }
                sink.finish()
                return
            }
            let lines: [Data] = buffer.withLock { b in
                b.append(chunk)
                var out: [Data] = []
                while let nl = b.firstIndex(of: 0x0A) {
                    out.append(b.subdata(in: b.startIndex..<nl))
                    b.removeSubrange(b.startIndex...nl)
                }
                return out
            }
            for l in lines where !l.isEmpty { sink.yield(String(decoding: l, as: UTF8.self)) }
        }
        return stream
    }
}

/// The last `limit` lines of a stream of text, safe to append from any thread.
final class TextTail: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String]())
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data) {
        let new = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        state.withLock { lines in
            lines += new
            if lines.count > limit { lines.removeFirst(lines.count - limit) }
        }
    }

    var text: String { state.withLock { $0.joined(separator: "\n") } }
}
