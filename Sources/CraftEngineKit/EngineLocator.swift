import Foundation

/// Where the pinned engine (`craft-anything-cli`) is, and how to start its MCP server.
public enum EngineLocator {
    public static let programName = "craft-anything-cli"

    /// The engine to run: `$CRAFT_ANYTHING_ENGINE`, else one inside the app bundle, else
    /// `Engine/bin/` in a folder above this program (a `swift build` in this repository, after
    /// `Tools/engine/pin-engine.sh`).
    public static func find(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fm = FileManager.default
        if let path = environment["CRAFT_ANYTHING_ENGINE"], fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: programName), fm.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let d = dir, d.path != "/" {
            let candidate = d.appendingPathComponent("Engine/bin/\(programName)")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }

    /// What `Tools/engine/pin-engine.sh` recorded beside the engine (`commit`, `version`, `sha256`).
    public static func pin(of engine: URL) -> [String: String] {
        let file = engine.deletingLastPathComponent().appendingPathComponent("pin.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { out[String(parts[0])] = String(parts[1]) }
        }
        return out
    }

    /// The engine's environment: ours, without what marks a process as running inside a Claude
    /// Code session (the builder it starts would think it was nested), plus the usual install
    /// folders on PATH, since an app opened from the Dock gets the system's short PATH. Homebrew's
    /// rustup is keg-only: its `cargo` is in `opt/rustup/bin`, not `bin`, so builds of Rust stacks
    /// found no cargo.
    public static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base.filter { key, _ in key != "CLAUDECODE" && !key.hasPrefix("CLAUDE_CODE_") }
        let home = env["HOME"] ?? NSHomeDirectory()
        let extra = [
            "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin",
            "/opt/homebrew/opt/rustup/bin", "/usr/local/opt/rustup/bin",
        ]
        var path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for p in extra where !path.contains(p) { path.append(p) }
        env["PATH"] = path.joined(separator: ":")
        return env
    }
}
