import Foundation
import os
import Testing

@testable import CraftEngineKit

/// A stand-in MCP server: answers by method, never answers `slow`, and exits on `quit`.
private let standIn = #"""
    #!/bin/sh
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      case "$line" in
        *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"serverInfo":{"name":"stand-in","version":"1"}}}\n' "$id" ;;
        *'"method":"notifications/initialized"'*) printf '{"jsonrpc":"2.0","method":"notifications/message","params":{"text":"hello"}}\n' ;;
        *'"method":"notifications/cancelled"'*) ;;
        *'"method":"slow"'*) ;;
        *'"method":"bad"'*) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Unknown method"}}\n' "$id" ;;
        *'"method":"quit"'*) echo "bye from stderr" >&2; exit 3 ;;
        *) printf '{"jsonrpc":"2.0","id":%s,"result":{"echo":true}}\n' "$id" ;;
      esac
    done
    """#

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cany-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func standInClient(_ source: String = standIn) throws -> MCPClient {
    let script = try tempDir().appendingPathComponent("stand-in.sh")
    try source.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return MCPClient(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path])
}

/// The first event that matches, or nil after `seconds`.
private func firstEvent(_ client: MCPClient, within seconds: Double, where match: @escaping @Sendable (EngineEvent) -> Bool) async -> EngineEvent? {
    await withTaskGroup(of: EngineEvent?.self) { group in
        group.addTask {
            for await e in client.events where match(e) { return e }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

@Suite struct JSONValueTests {
    @Test func roundTripsAndSendsWholeNumbersAsIntegers() throws {
        let v: JSONValue = ["n": 3, "x": 1.5, "s": "a/b\nc", "b": true, "z": .null, "a": [1, "two"]]
        let line = v.compact()
        #expect(!line.contains("\n"), "one line on the wire")
        #expect(line.contains("\"n\":3"))
        #expect(!line.contains("3.0"))
        #expect(JSONValue.parse(line) == v)
        #expect(v["a"]?.array?.count == 2)
        #expect(v["n"]?.int == 3)
        #expect(v["x"]?.int == nil)
        #expect(JSONValue.parse("not json") == nil)
    }
}

@Suite struct ToolTests {
    @Test func readsResultsAndErrorsTheEngineSends() {
        let ok = ToolResult(json: ["content": [["type": "text", "text": "{\"result\":{\"count\":0}}"]], "isError": false, "structuredContent": ["result": ["count": 0]]])
        #expect(!ok.isError)
        #expect(ok.result?["count"]?.int == 0)
        #expect(ok.errorMessage == nil)
        // Failures carry the ToolError JSON as text only.
        let text = #"{"error":{"category":"missing","code":"not_found","message":"/nope isn't a project folder.","remediation":"Pass a folder from project_list.","retryable":false}}"#
        let bad = ToolResult(json: ["content": [["type": "text", "text": .string(text)]], "isError": true])
        #expect(bad.isError)
        #expect(bad.result == nil)
        #expect(bad.errorCode == "not_found")
        #expect(bad.errorMessage == "/nope isn't a project folder. Pass a folder from project_list.")
    }

    @Test func readsParameterKindsFromSchemas() throws {
        let json = JSONValue.parse(#"""
            {"name":"rebuild_start","title":"Start","description":"Start building.","annotations":{"readOnlyHint":false},
             "inputSchema":{"type":"object","required":["request"],"properties":{
               "request":{"type":"string"},
               "rounds":{"type":["integer","null"],"default":null},
               "resume":{"type":"boolean","default":false},
               "pictures":{"type":"array","items":{"type":"string"}},
               "existing":{"anyOf":[{"$ref":"#/$defs/ExistingFiles"},{"type":"null"}]},
               "mode":{"type":"string","enum":["edit","start_from"]}}}}
            """#)
        let tool = try #require(json.flatMap(EngineTool.init(json:)))
        #expect(tool.area == "rebuild")
        let kinds = Dictionary(uniqueKeysWithValues: tool.parameters.map { ($0.name, $0.kind) })
        #expect(tool.parameters.first?.name == "request", "required first")
        #expect(kinds["request"] == .string)
        #expect(kinds["rounds"] == .integer)
        #expect(kinds["resume"] == .boolean)
        #expect(kinds["pictures"] == .stringList)
        #expect(kinds["existing"] == .json)
        #expect(kinds["mode"] == .choice(["edit", "start_from"]))
    }
}

@Suite struct InboxTests {
    @Test func listsWhatWaitsAndAnswersWhole() throws {
        let dir = try tempDir()
        let inbox = Inbox(directory: dir)
        let request = #"{"id":"r-2","kind":"approval","title":"Allow: Start building","detail":"why","action":"rebuild_start","created_ms":20}"#
        try request.write(to: dir.appendingPathComponent("r-2.request.json"), atomically: true, encoding: .utf8)
        try #"{"id":"q-1","kind":"question","title":"Which colour?","choices":["Red","Blue"],"allow_text":true,"created_ms":10}"#
            .write(to: dir.appendingPathComponent("q-1.request.json"), atomically: true, encoding: .utf8)
        // Hostile or broken files are skipped.
        try "{".write(to: dir.appendingPathComponent("broken.request.json"), atomically: true, encoding: .utf8)
        try request.write(to: dir.appendingPathComponent("BAD_ID.request.json"), atomically: true, encoding: .utf8)
        try request.write(to: dir.appendingPathComponent("other.request.json"), atomically: true, encoding: .utf8)

        let waiting = inbox.pending()
        #expect(waiting.map(\.id) == ["q-1", "r-2"], "oldest first, broken and mismatched ids skipped")
        #expect(waiting.first?.choices == ["Red", "Blue"])
        #expect(waiting.first?.allowText == true)
        #expect(waiting.last?.kind == .approval)

        try inbox.answer("r-2", .approve(always: true))
        #expect(inbox.pending().map(\.id) == ["q-1"])
        let saved = try JSONDecoder().decode(InboxAnswer.self, from: Data(contentsOf: dir.appendingPathComponent("r-2.answer.json")))
        #expect(saved == InboxAnswer(allow: true, always: true))
        #expect(throws: EngineError.self) { try inbox.answer("../escape", .deny) }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func idsFollowTheEnginesRule() {
        #expect(Inbox.isValid("a-1"))
        #expect(!Inbox.isValid(""))
        #expect(!Inbox.isValid("A"))
        #expect(!Inbox.isValid("a/b"))
        #expect(!Inbox.isValid(String(repeating: "a", count: 65)))
    }
}

@Suite struct MCPClientTests {
    @Test func talksJSONRPCAndPassesNotificationsOn() async throws {
        let client = try standInClient()
        try await client.start()
        let hello = Task { await firstEvent(client, within: 5) { if case .notification("notifications/message", _) = $0 { true } else { false } } }
        let info = try await client.initialize(clientName: "tests", version: "0")
        #expect(info["serverInfo"]?["name"]?.string == "stand-in")
        #expect(await hello.value != nil, "notifications reach events")
        // Overlapping requests each get their own reply.
        async let a = client.request("ping", [:], timeout: .seconds(5))
        async let b = client.request("ping", [:], timeout: .seconds(5))
        let (ra, rb) = try await (a, b)
        #expect(ra["echo"]?.bool == true && rb["echo"]?.bool == true)
        await #expect(throws: EngineError(code: -32601, "Unknown method")) { try await client.request("bad", [:], timeout: .seconds(5)) }
        await client.stop()
        #expect(await !client.isRunning)
    }

    @Test func aRequestNobodyAnswersTimesOut() async throws {
        let client = try standInClient()
        try await client.start()
        let start = ContinuousClock.now
        await #expect(throws: EngineError.self) { try await client.request("slow", [:], timeout: .milliseconds(300)) }
        #expect(ContinuousClock.now - start < .seconds(3))
        // The connection still works after a timeout.
        #expect(try await client.request("ping", [:], timeout: .seconds(5))["echo"]?.bool == true)
        await client.stop()
    }

    @Test func cancellingTheCallerCancelsTheRequest() async throws {
        let client = try standInClient()
        try await client.start()
        let start = ContinuousClock.now
        let call = Task { try await client.request("slow", [:], timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(200))
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(try await client.request("ping", [:], timeout: .seconds(5))["echo"]?.bool == true)
        await client.stop()
    }

    /// Busy engines ignore stdin closing: one leaves on a second SIGTERM, as the CLI does (its first
    /// is taken as Ctrl-C), and one ignores SIGTERM altogether.
    @Test(arguments: [
        "trap 'if [ -n \"$t\" ]; then exit 130; fi; t=1' TERM",
        "trap '' TERM",
    ])
    func stopEndsABusyEngine(trap: String) async throws {
        let client = try standInClient("#!/bin/sh\n\(trap)\nwhile :; do sleep 0.1; done\n")
        try await client.start()
        let start = ContinuousClock.now
        await client.stop(grace: .milliseconds(200))
        #expect(await !client.isRunning)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func anEngineThatStopsFailsWhatWaitsAndSaysWhy() async throws {
        let client = try standInClient()
        try await client.start()
        let exited = Task { await firstEvent(client, within: 5) { if case .exited = $0 { true } else { false } } }
        await #expect(throws: EngineError.self) { try await client.request("quit", [:], timeout: .seconds(5)) }
        guard case .exited(let status, let stderr)? = await exited.value else {
            Issue.record("no exit event")
            return
        }
        #expect(status == 3)
        #expect(stderr.contains("bye from stderr"))
        await #expect(throws: EngineError.self) { try await client.request("ping", [:], timeout: .seconds(1)) }
    }

    @Test func aMissingProgramIsAnError() async {
        let client = MCPClient(executable: URL(fileURLWithPath: "/nonexistent/craft-anything-cli"), arguments: ["mcp"])
        await #expect(throws: EngineError.self) { try await client.start() }
    }
}

/// A native tool for the tests: echoes its arguments, or waits forever when told to.
private struct EchoTool: NativeTool {
    let name = "native_echo"
    func call(_ arguments: JSONValue, meta: JSONValue) async -> JSONValue {
        if arguments["wait"]?.bool == true { try? await Task.sleep(for: .seconds(3600)) }
        return ["content": [["type": "text", "text": "native"]], "structuredContent": ["result": arguments]]
    }
}

@Suite struct ToolServerTests {
    @Test func passesTheEngineThroughAndAnswersNativeToolsItself() async throws {
        let script = try tempDir().appendingPathComponent("stand-in.sh")
        try standIn.write(to: script, atomically: true, encoding: .utf8)
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let server = ToolServer(
            engine: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path], environment: [:], native: [EchoTool()],
            log: { line in calls.withLock { $0.append(line) } })
        let input = Pipe(), output = Pipe()
        let run = Task { try await server.run(input: input.fileHandleForReading, output: output.fileHandleForWriting) }
        var replies = LineSplitter.stream(from: output.fileHandleForReading).makeAsyncIterator()
        func send(_ m: JSONValue) throws { try input.fileHandleForWriting.write(contentsOf: Data((m.compact() + "\n").utf8)) }

        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        #expect(JSONValue.parse(await replies.next() ?? "")?["result"]?["serverInfo"]?["name"]?.string == "stand-in")
        // The engine's own tool goes through; the native one is answered here.
        try send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "core_session_show", "arguments": [:]]])
        #expect(JSONValue.parse(await replies.next() ?? "")?["result"]?["echo"]?.bool == true)
        try send(["jsonrpc": "2.0", "id": "three", "method": "tools/call", "params": ["name": "native_echo", "arguments": ["x": 1]]])
        let native = JSONValue.parse(await replies.next() ?? "")
        #expect(native?["id"]?.string == "three")
        #expect(native?["result"]?["structuredContent"]?["result"]?["x"]?.int == 1)
        // A cancelled native call gets no reply, and what follows still works.
        try send(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "native_echo", "arguments": ["wait": true]]])
        try send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 4]])
        try send(["jsonrpc": "2.0", "id": 5, "method": "ping"])
        #expect(JSONValue.parse(await replies.next() ?? "")?["id"]?.int == 5)
        // Closing the input lets the engine finish and the server return its status.
        try input.fileHandleForWriting.close()
        #expect(try await run.value == 0)
        #expect(calls.withLock { $0 }.contains("call core_session_show"))
        #expect(calls.withLock { $0 }.contains("call native_echo (native)"))
    }
}

@Suite struct EngineLocatorTests {
    @Test func theEngineGetsAFullPathAndNoClaudeCodeMarks() {
        let env = EngineLocator.environment(base: [
            "HOME": "/Users/x", "PATH": "/usr/bin:/bin", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "LANG": "en_US.UTF-8",
        ])
        #expect(env["CLAUDECODE"] == nil && env["CLAUDE_CODE_ENTRYPOINT"] == nil)
        #expect(env["LANG"] == "en_US.UTF-8")
        let path = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(Array(path.prefix(2)) == ["/usr/bin", "/bin"], "the PATH it was given comes first")
        for p in ["/Users/x/.local/bin", "/opt/homebrew/bin", "/Users/x/.cargo/bin", "/opt/homebrew/opt/rustup/bin"] {
            #expect(path.contains(p), "\(p)")
        }
        #expect(Set(path).count == path.count)
    }
}

/// Against the pinned engine, when Tools/engine/pin-engine.sh has put one in Engine/bin. Its
/// settings, projects and inbox go to temp folders.
@Suite struct PinnedEngineTests {
    static var engine: URL? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let e = root.appendingPathComponent("Engine/bin/craft-anything-cli")
        return FileManager.default.isExecutableFile(atPath: e.path) ? e : nil
    }

    @Test(.enabled(if: engine != nil)) func listsEveryToolAndAnswersCalls() async throws {
        let engine = try #require(Self.engine)
        let config = try tempDir()
        let inbox = try tempDir()
        var env = EngineLocator.environment()
        env["CRAFT_ANYTHING_CONFIG_DIR"] = config.path
        let client = MCPClient(executable: engine, arguments: ["mcp", "--all-tools", "--inbox", inbox.path], environment: env)
        try await client.start()
        let info = try await client.initialize(clientName: "tests", version: "0")
        #expect(info["serverInfo"]?["name"]?.string == "craft-anything")
        let tools = try await client.listTools()
        // Clean room (the default) lists only the tools that work from outside a target.
        #expect(tools.count > 50)
        #expect(tools.contains { $0.name == "rebuild_start" })
        let session = try await client.callTool("core_session_show")
        #expect(session.result?["clean_room"]?.bool == true)
        let missing = try await client.callTool("rebuild_status", ["project": .string(config.appendingPathComponent("nope").path)])
        #expect(missing.errorCode == "not_found")
        await client.stop()
    }

    /// Clean room refuses a look inside with a refusal the app can tell apart; `settings_set deep_mode`
    /// switches the running engine at once, lists the tools that look inside, and saves it for the
    /// engine processes it starts later. Switching back refuses again.
    @Test(.enabled(if: engine != nil)) func deepModeSwitchesTheRunningEngine() async throws {
        let engine = try #require(Self.engine)
        let config = try tempDir()
        var env = EngineLocator.environment()
        env["CRAFT_ANYTHING_CONFIG_DIR"] = config.path
        let client = MCPClient(executable: engine, arguments: ["mcp", "--all-tools", "--inbox", try tempDir().path], environment: env)
        try await client.start()
        _ = try await client.initialize(clientName: "tests", version: "0")
        let cleanTools = try await client.listTools().count

        let refused = try await client.callTool("core_target_open", ["path": "/usr/bin/true"])
        #expect(refused.isCleanRoomRefusal, "\(refused.text)")
        #expect(refused.errorCode == "feature_missing")
        let missing = try await client.callTool("rebuild_status", ["project": .string(config.appendingPathComponent("nope").path)])
        #expect(missing.isError && !missing.isCleanRoomRefusal, "other failures aren't refusals")

        let set = try await client.callTool("settings_set", ["key": "deep_mode", "value": true])
        #expect(!set.isError, "\(set.text)")
        #expect(try await client.callTool("core_session_show").result?["clean_room"]?.bool == false)
        #expect(try await client.listTools().count > cleanTools, "Deep mode lists the tools that look inside")
        let engines = try await client.callTool("engines_list")
        #expect(engines.result?["deep_mode"]?["enabled"]?.bool == true)
        let saved = try String(contentsOf: config.appendingPathComponent("config.toml"), encoding: .utf8)
        #expect(saved.contains("deep_mode = true"), "saved for the engine processes it starts")
        let opened = try await client.callTool("core_target_open", ["path": "/usr/bin/true"])
        #expect(!opened.isCleanRoomRefusal, "\(opened.text)")

        _ = try await client.callTool("settings_set", ["key": "deep_mode", "value": false])
        #expect(try await client.listTools().count == cleanTools)
        #expect(try await client.callTool("core_target_triage").isCleanRoomRefusal)
        await client.stop()
    }

    /// A call with a progress token gets the engine's progress reports for it.
    @Test func callsCanAskForProgress() async throws {
        let echo = try tempDir().appendingPathComponent("echo.py")
        // A stand-in server: answers each request with the `_meta` it was sent.
        try """
            import json, sys
            for line in sys.stdin:
                m = json.loads(line)
                if "id" in m:
                    meta = m.get("params", {}).get("_meta", {})
                    print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": {"content": [{"type": "text", "text": json.dumps({"result": meta})}]}}), flush=True)
            """.write(to: echo, atomically: true, encoding: .utf8)
        let client = MCPClient(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-I", echo.path], environment: EngineLocator.environment())
        try await client.start()
        let with = try await client.callTool("x", progressToken: "t-1")
        #expect(with.result?["progressToken"]?.string == "t-1")
        let without = try await client.callTool("x")
        #expect(without.result?["progressToken"] == nil)
        await client.stop()
    }

    /// A call that needs consent asks through the inbox and waits; a denial refuses it and nothing
    /// starts. (Allowing would start a real build, so only the refusal is tested here.)
    @Test(.enabled(if: engine != nil)) func consentIsAskedThroughTheInbox() async throws {
        let engine = try #require(Self.engine)
        let config = try tempDir()
        let projects = try tempDir()
        let inbox = Inbox(directory: try tempDir())
        var env = EngineLocator.environment()
        env["CRAFT_ANYTHING_CONFIG_DIR"] = config.path
        let client = MCPClient(executable: engine, arguments: ["mcp", "--inbox", inbox.directory.path], environment: env)
        try await client.start()
        _ = try await client.initialize(clientName: "tests", version: "0")
        let call = Task { try await client.callTool("rebuild_start", ["request": "A page", "target": "-", "projects_dir": .string(projects.path)], timeout: .seconds(30)) }
        var asked: InboxRequest?
        for _ in 0..<100 where asked == nil {
            try await Task.sleep(for: .milliseconds(100))
            asked = inbox.pending().first
        }
        let request = try #require(asked, "the engine asks before starting a build")
        #expect(request.kind == .approval)
        try inbox.answer(request.id, .deny)
        let result = try await call.value
        #expect(result.isError)
        #expect(try FileManager.default.contentsOfDirectory(atPath: projects.path).isEmpty, "nothing was started")
        await client.stop()
    }
}
