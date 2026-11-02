import CraftEngineKit
import Foundation

// The tool server agents get in place of `craft-anything-cli` (CRAFT_ANYTHING_TOOL_SERVER): `mcp …`
// is served through ToolServer, so native tools can answer under the engine's ids; anything else
// (`builder-notes <dir>`, the notes hook) becomes the engine itself.

let args = Array(CommandLine.arguments.dropFirst())
guard let engine = EngineLocator.find() else {
    FileHandle.standardError.write(Data("No engine: set CRAFT_ANYTHING_ENGINE to a craft-anything-cli.\n".utf8))
    exit(127)
}

guard args.first == "mcp" else {
    let argv = ([engine.path] + args).map { strdup($0) } + [nil]
    execv(engine.path, argv)
    FileHandle.standardError.write(Data("Couldn't start \(engine.path): \(String(cString: strerror(errno)))\n".utf8))
    exit(126)
}

/// One line per call in ~/Library/Logs/CraftAnythingNative/tool-server.log, so a run shows what
/// went where.
let logFile: FileHandle? = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CraftAnythingNative")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("tool-server.log")
    if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
    let handle = try? FileHandle(forWritingTo: file)
    _ = try? handle?.seekToEnd()
    return handle
}()
let pid = ProcessInfo.processInfo.processIdentifier
let log: ToolServer.Log = { line in
    let stamp = ISO8601DateFormatter().string(from: Date())
    try? logFile?.write(contentsOf: Data("\(stamp) [\(pid)] \(line)\n".utf8))
}

let server = ToolServer(engine: engine, arguments: args, environment: ProcessInfo.processInfo.environment, native: [], log: log)
do {
    let status = try await server.run(input: .standardInput, output: .standardOutput, forwardSignals: true)
    exit(status)
} catch {
    FileHandle.standardError.write(Data("Couldn't start \(engine.path): \(error.localizedDescription)\n".utf8))
    exit(126)
}
