import AppKit
import CraftEngineKit
import CraftWebKit
import Foundation

// The engine's plugin for tools served natively (`[[plugins.mcp]]` with `replaces` in its
// config.toml): an MCP server on stdio. WebKit needs an application and the main run loop, so the
// server reads stdin on its own task while the app runs; it never shows a window or activates,
// and it quits when the engine closes stdin.

/// The `config.toml` entry that sends the engine's browser set here.
if CommandLine.arguments.dropFirst().first == "--print-config" {
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
    print("""
        [[plugins.mcp]]
        id = "mac_app"
        name = "Craft Anything for Mac"
        command = "\(me)"
        replaces = ["web_site_open", "web_site_capture", "web_page_states_capture", "web_site_close"]
        """)
    exit(0)
}

let logFile: FileHandle? = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CraftAnythingNative")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("native-tools.log")
    if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
    let handle = try? FileHandle(forWritingTo: file)
    _ = try? handle?.seekToEnd()
    return handle
}()
let pid = ProcessInfo.processInfo.processIdentifier
let log: MCPServer.Log = { line in
    let stamp = ISO8601DateFormatter().string(from: Date())
    try? logFile?.write(contentsOf: Data("\(stamp) [\(pid)] \(line)\n".utf8))
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let server = MCPServer(name: "craft-anything-native-tools", version: "0.1", tools: WebKitBrowserTools.all(), log: log)
Task.detached {
    log("started")
    await server.run(input: .standardInput, output: .standardOutput)
    log("input closed")
    exit(0)
}
app.run()
