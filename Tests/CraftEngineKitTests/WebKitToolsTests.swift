import Foundation
import Testing

@testable import CraftEngineKit
@testable import CraftWebKit

private func solid(_ w: Int, _ h: Int, _ v: UInt8) -> RGBAImage {
    RGBAImage(width: w, height: h, pixels: (0..<(w * h)).flatMap { _ in [v, v, v, 255] })
}

@Suite struct WebKitPartsTests {
    @Test func noiseIsFoundByTheEnginesTileRule() throws {
        let a = solid(64, 64, 200)
        #expect(NoiseMask(between: a, a, threshold: 24).count == 0)
        var b = a
        // One tile (16..<32, 16..<32) changes: it and its neighbours are noise, 3×3 tiles.
        for y in 16..<32 { for x in 16..<32 { let o = (y * 64 + x) * 4; b.pixels[o] = 0; b.pixels[o + 1] = 0; b.pixels[o + 2] = 0 } }
        let m = NoiseMask(between: a, b, threshold: 24)
        #expect((m.cols, m.rows, m.count) == (4, 4, 9))
        #expect(m.union(NoiseMask(between: a, a, threshold: 24)) == m)
        let png = try #require(m.png())
        let back = try #require(RGBAImage(png: png))
        #expect((back.width, back.height) == (4, 4))
        #expect(back.pixels[0] == 255 && back.pixels[(3 * 4 + 3) * 4] == 0, "white where it changes")
    }

    @Test func aVisitorSeesNoCodeOrRequests() {
        let b: JSONValue = [
            "url": "https://a.test/", "title": "A", "meta": ["description": "d"], "breakpoints": [], "health": [:],
            "design": ["fonts": [["value": "Inter", "count": 3]], "css_variables": ["--x": "1"]],
            "assets": ["images": [["src": "https://a.test/p.png", "w": 10, "h": 20]], "scripts": ["https://a.test/s.js"]],
        ]
        let v = CaptureReport.visitorView(b)
        #expect(v["meta"] == nil && v["health"] == nil && v["breakpoints"] == nil && v["design"]?["css_variables"] == nil)
        #expect(v["assets"] == ["images": [["w": 10, "h": 20]]])
        let md = CaptureReport.readme(v, shots: [["file": "screenshot-1440.png", "width": 1440, "height": 900, "cut": false]], htmlBytes: 0, visitor: true)
        #expect(md.hasPrefix("# Capture of https://a.test/\n"))
        #expect(md.contains("- `screenshot-1440.png` — 1440×900 px screenshot\n"))
        #expect(md.contains("- Fonts: `Inter`\n") && md.contains("Clean room: only what a visitor sees"))
        #expect(!md.contains("## Page health"))
    }

    @Test func argumentsAndAddressesAreCheckedAsTheEngineChecksThem() throws {
        #expect(throws: ToolFailure.self) { try Arguments(["url": "x", "nope": 1], allowed: ["url"]) }
        let a = try Arguments(["widths": [1440, 390]], allowed: ["widths", "max_height"])
        #expect(try a.ints("widths", []) == [1440, 390] && a.int("max_height", 12_000) == 12_000)
        #expect(try checkURL("https://example.com/x").host == "example.com")
        for bad in ["file:///etc/hosts", "https://", "https:///x", "javascript:alert(1)", "https://a b"] {
            #expect(throws: ToolFailure.self, "\(bad)") { try checkURL(bad) }
        }
        #expect(shownURL("https://u:p@a.test/x?token=1#y") == "https://a.test/x")
        #expect(ToolFailure.noSite.json["category"] == "missing")
    }

    @MainActor @Test func aPhoneLaysThePageOutAsItsViewportTagAsks() {
        #expect(SiteBrowser.phoneLayout(width: 390, viewport: "width=device-width, initial-scale=1") == 390)
        #expect(SiteBrowser.phoneLayout(width: 390, viewport: "width=1120") == 1120)
        #expect(SiteBrowser.phoneLayout(width: 390, viewport: nil) == 980, "no tag: what phone browsers use")
        #expect(SiteBrowser.phoneLayout(width: 390, viewport: "initial-scale=1") == 390)
        #expect(SiteBrowser.phoneLayout(width: 390, viewport: "width=200") == 390, "never narrower than the phone")
        #expect(SiteBrowser.View(width: 390, layout: 980, frame: 980).scale < 0.4)
    }

    @Test func aClickIsDescribedByWhatChanged() {
        let before: JSONValue = ["expanded": "false", "selected": .null, "open": .null, "dialogs": 0, "url": "https://a.test/"]
        #expect(StatesTool.change(before, ["expanded": "true", "dialogs": 0, "url": "https://a.test/"]) == ["expanded"])
        #expect(StatesTool.change(before, ["expanded": "false", "dialogs": 1, "url": "https://a.test/"]) == ["dialog appeared"])
        #expect(StatesTool.change(before, ["expanded": "false", "dialogs": 0, "url": "https://a.test/b"]) == ["address changed"])
        #expect(StatesTool.change(before, before).isEmpty)
        #expect(PageScripts.findStates.contains("__MAX__") && PageScripts.state.contains("__I__") && PageScripts.clickState.contains("__I__"))
    }
}

private struct Greeter: NativeTool {
    let name = "greet"
    func call(_ arguments: JSONValue, meta: JSONValue) async -> JSONValue {
        if arguments["wait"]?.bool == true { try? await Task.sleep(for: .seconds(3600)) }
        return ["structuredContent": ["result": ["hello": arguments["who"] ?? .null, "meta": meta]]]
    }
}

@Suite struct MCPServerTests {
    @Test func answersTheHandshakeListsAndCallsAndDropsCancelledCalls() async throws {
        let server = MCPServer(name: "test", version: "1", tools: [Greeter()])
        let input = Pipe(), output = Pipe()
        let run = Task { await server.run(input: input.fileHandleForReading, output: output.fileHandleForWriting) }
        var replies = LineSplitter.stream(from: output.fileHandleForReading).makeAsyncIterator()
        func send(_ m: JSONValue) throws { try input.fileHandleForWriting.write(contentsOf: Data((m.compact() + "\n").utf8)) }
        func next() async -> JSONValue? { JSONValue.parse(await replies.next() ?? "") }

        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        #expect(await next()?["result"]?["serverInfo"]?["name"] == "test")
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        #expect(await next()?.at("/result/tools/0/name") == "greet")
        try send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "greet", "arguments": ["who": "you"], "_meta": ["clean_room": true]]])
        let r = await next()?["result"]?["structuredContent"]?["result"]
        #expect(r?["hello"] == "you" && r?["meta"]?["clean_room"] == .bool(true), "the request's _meta reaches the tool")
        try send(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "nope"]])
        #expect(await next()?["error"]?["code"]?.int == -32602)
        try send(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "greet", "arguments": ["wait": true]]])
        try send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 5]])
        try send(["jsonrpc": "2.0", "id": 6, "method": "ping"])
        #expect(await next()?["id"]?.int == 6, "the cancelled call got no reply")
        try input.fileHandleForWriting.close()
        await run.value
    }
}

/// The built plugin, when `swift build` made one.
private let nativeTools: URL? = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let exe = root.appendingPathComponent(".build/debug/craft-anything-native-tools")
    return FileManager.default.isExecutableFile(atPath: exe.path) ? exe : nil
}()

@Suite struct WebKitBrowserLiveTests {
    /// A page served on loopback by python3's http.server, and its address.
    private func servePage(_ html: String) throws -> (Process, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cany-site-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let port = Int.random(in: 20_000..<60_000)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", dir.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return (p, "http://127.0.0.1:\(port)/")
    }

    @Test(.enabled(if: nativeTools != nil && FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")), .timeLimit(.minutes(2)))
    func capturesAPageAndItsMenuWithWebKit() async throws {
        let (site, url) = try servePage("""
            <!doctype html><html lang="en"><head><title>Live</title><style>body{margin:0;font:16px sans-serif}main{max-width:600px;margin:auto;padding:40px}
            [role=menu]{display:none}[aria-expanded=true]+[role=menu]{display:block}</style></head><body><main><h1>Hello</h1>
            <button aria-expanded="false" onclick="this.setAttribute('aria-expanded','true')">Menu</button><div role="menu">Inside</div>
            <p style="height:1500px">Tall</p><script>console.error('planted error')</script></main></body></html>
            """)
        defer { site.terminate() }
        try await Task.sleep(for: .milliseconds(800))
        let client = MCPClient(executable: try #require(nativeTools), arguments: [])
        try await client.start()
        defer { Task { await client.stop() } }
        _ = try await client.initialize(clientName: "test", version: "1")
        func call(_ name: String, _ arguments: JSONValue, meta: JSONValue? = nil) async throws -> JSONValue {
            var params: [String: JSONValue] = ["name": .string(name), "arguments": arguments]
            if let meta { params["_meta"] = meta }
            return try await client.request("tools/call", .object(params), timeout: .seconds(60))
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("cany-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let opened = try await call("web_site_open", ["url": .string(url), "settle_ms": 300], meta: ["clean_room": false])
        #expect(opened["structuredContent"]?["result"]?["title"] == "Live")
        #expect(opened.at("/structuredContent/result/health/errors/0/text") == "planted error", "console errors are kept")
        let width = opened.at("/structuredContent/result/facts/width")?.int ?? 0
        #expect((1400..<1440).contains(width), "a page that scrolls keeps a scrollbar gutter, as in Chromium: \(width)")

        let cap = try await call("web_site_capture", ["output_directory": .string(out.appendingPathComponent("c").path), "widths": [800]])
        #expect(cap["isError"] == nil, "\(cap)")
        let files = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("c").path).sorted()
        #expect(files == ["README.md", "capture.json", "page.html", "screenshot-800.png"])
        let shot = try #require(RGBAImage(png: try Data(contentsOf: out.appendingPathComponent("c/screenshot-800.png"))))
        #expect(shot.width == 800 && shot.height > 1500, "the whole page, one pixel per CSS pixel")

        let states = try await call("web_page_states_capture", ["output_directory": .string(out.appendingPathComponent("s").path)])
        #expect(states.at("/structuredContent/result/states/0/changed") == ["expanded"])

        let visitor = try await call("web_site_capture", ["output_directory": .string(out.appendingPathComponent("v").path), "widths": [800]], meta: ["clean_room": true])
        #expect(visitor["isError"] == nil)
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("v/page.html").path), "Clean room keeps no HTML")
        let closed = try await call("web_site_close", [:])
        #expect(closed["structuredContent"] == ["result": ["closed": true]])
    }
}
