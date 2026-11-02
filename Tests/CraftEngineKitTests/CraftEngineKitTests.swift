import Foundation
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
