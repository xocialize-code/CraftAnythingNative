import CraftEngineKit
import Foundation
import Observation

/// A project, as `project_list` sums it up.
struct ProjectSummary: Identifiable, Hashable {
    var name: String
    var folder: String
    var request: String
    var stack: String
    var status: String
    var statusLabel: String
    var note: String
    var updatedMs: Double
    var waiting: Int

    var id: String { folder }

    init?(json: JSONValue) {
        guard let folder = json["folder"]?.string else { return nil }
        self.folder = folder
        name = json["name"]?.string ?? URL(fileURLWithPath: folder).lastPathComponent
        request = json["request"]?.string ?? ""
        stack = json["stack"]?.string ?? ""
        status = json["status"]?.string ?? ""
        statusLabel = json["status_label"]?.string ?? status
        note = json["note"]?.string ?? ""
        updatedMs = json["updated_ms"]?.number ?? 0
        waiting = json["waiting"]?.int ?? 0
    }
}

/// The app's one connection to the pinned engine: starting it, the tools it lists, the projects
/// it knows, and the approvals it posts to this app's inbox.
@MainActor @Observable
final class EngineModel {
    enum Phase: Equatable {
        case starting
        case ready
        case failed(String)
    }

    var phase: Phase = .starting
    var engineVersion = ""
    var enginePath = ""
    var pin: [String: String] = [:]
    /// Clean room (the default) or Deep mode, as the running engine has it.
    var cleanRoom = true
    /// Clean room ↔ Deep is being switched.
    var switchingMode = false
    /// Ghidra's launcher when it's installed: Deep mode's decompiler for programs.
    var ghidraPath: String?
    /// Ghidra can be installed for the person on this Mac (`engines_install`).
    var ghidraInstallable = false
    var installingGhidra = false
    /// What the engine last reported about the Ghidra download.
    var ghidraProgress = ""
    /// The asset budget a new game starts with (`assets.budget_usd`).
    var assetBudget = 5.0
    /// An asset provider's key is stored, so a game may generate pictures and 3D models.
    var assetKeyStored = false
    var tools: [EngineTool] = []
    var projects: [ProjectSummary] = []
    var projectsDir = ""
    /// Approvals and questions waiting in this app's inbox (consent for the calls it makes).
    var waiting: [InboxRequest] = []
    /// The last things the engine reported on its own (progress, list changes).
    var activity: [String] = []

    let inbox: Inbox
    /// For a check run: the engine keeps its settings and projects here instead of the person's.
    let configDir: URL?

    private var client: MCPClient?
    /// The progress token whose reports go to `ghidraProgress`.
    private var progressWatch: String?
    private var watchers: [Task<Void, Never>] = []

    init(inboxDir: URL, configDir: URL? = nil) {
        try? FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        inbox = Inbox(directory: inboxDir)
        self.configDir = configDir
    }

    /// Start the engine (stopping a running one first) and load its tools and projects.
    func start() async {
        await stop()
        phase = .starting
        guard let engine = EngineLocator.find() else {
            phase = .failed("No engine found. Run Tools/engine/pin-engine.sh, or set CRAFT_ANYTHING_ENGINE to a craft-anything-cli.")
            return
        }
        enginePath = engine.path
        pin = EngineLocator.pin(of: engine)
        // Builders the engine starts reach it through our tool server, where native tools answer.
        var env = EngineLocator.environment(engine: engine, toolServer: EngineLocator.findToolServer())
        if let configDir { env["CRAFT_ANYTHING_CONFIG_DIR"] = configDir.path }
        let client = MCPClient(executable: engine, arguments: ["mcp", "--all-tools", "--inbox", inbox.directory.path], environment: env)
        do {
            try await client.start()
            let info = try await client.initialize(clientName: "CraftAnythingNative", version: "0.1.0")
            engineVersion = info["serverInfo"]?["version"]?.string ?? "?"
            self.client = client
            watch(client)
            tools = try await client.listTools().sorted { $0.name < $1.name }
            await refreshSettings()
            phase = .ready
            await refreshProjects()
        } catch {
            await client.stop()
            self.client = nil
            phase = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        if let client { await client.stop() }
        client = nil
    }

    /// Run a tool. Failures to reach the engine come back as an error result, like a tool's own.
    func call(_ name: String, _ arguments: JSONValue = [:], timeout: Duration = .seconds(120)) async -> ToolResult {
        guard let client else { return Self.failure("The engine isn't running.") }
        do {
            return try await client.callTool(name, arguments, timeout: timeout)
        } catch {
            return Self.failure(error.localizedDescription)
        }
    }

    /// Re-read the mode, Ghidra and the asset settings from the engine.
    func refreshSettings() async {
        async let session = call("core_session_show")
        async let engines = call("engines_list")
        async let settings = call("settings_show")
        async let key = call("assets_key_status")
        let (s, e, st, k) = await (session, engines, settings, key)
        if let clean = s.result?["clean_room"]?.bool { cleanRoom = clean }
        if let e = e.result {
            ghidraPath = e["deep_mode"]?["ghidra"]?.string
            ghidraInstallable = e["engines"]?.array?.first { $0["id"]?.string == "ghidra" }?["installable_here"]?.bool ?? false
        }
        if let budget = st.result?["settings"]?["assets"]?["budget_usd"]?.number { assetBudget = budget }
        if let stored = k.result?["stored"]?.bool { assetKeyStored = stored }
    }

    /// Switch between Clean room and Deep mode; nil when it worked, else why not. The engine saves
    /// it in its settings, so every engine process it starts (Study, checks, builders) follows. Its
    /// tool list changes with the mode, and it doesn't announce that, so the tools are listed again.
    func setDeepMode(_ on: Bool) async -> String? {
        switchingMode = true
        defer { switchingMode = false }
        let r = await call("settings_set", ["key": "deep_mode", "value": .bool(on)])
        if let failed = r.errorMessage { return failed }
        await refreshSettings()
        if let client, let listed = try? await client.listTools() { tools = listed.sorted { $0.name < $1.name } }
        note(on ? "Deep mode on" : "Clean room on")
        return nil
    }

    /// Download and install Ghidra into the engine's store; nil when it worked, else why not.
    func installGhidra() async -> String? {
        guard let client else { return "The engine isn't running." }
        installingGhidra = true
        ghidraProgress = ""
        defer { installingGhidra = false }
        let token = "ghidra-\(UUID().uuidString)"
        progressWatch = token
        defer { progressWatch = nil }
        let r: ToolResult
        do {
            r = try await client.callTool("engines_install", ["engine": "ghidra"], timeout: .seconds(2 * 60 * 60), progressToken: token)
        } catch {
            return error.localizedDescription
        }
        await refreshSettings()
        return r.errorMessage
    }

    func refreshProjects() async {
        let r = await call("project_list")
        guard let result = r.result else { return }
        projectsDir = result["projects_dir"]?.string ?? ""
        projects = (result["projects"]?.array ?? []).compactMap(ProjectSummary.init(json:)).sorted { $0.updatedMs > $1.updatedMs }
    }

    func answer(_ request: InboxRequest, _ answer: InboxAnswer) {
        do {
            try inbox.answer(request.id, answer)
            waiting.removeAll { $0.id == request.id }
        } catch {
            note("Couldn't answer: \(error.localizedDescription)")
        }
    }

    private func note(_ line: String) {
        activity.append(line)
        if activity.count > 50 { activity.removeFirst(activity.count - 50) }
    }

    private func watch(_ client: MCPClient) {
        watchers.append(Task { [weak self] in
            for await event in client.events {
                guard let self else { return }
                switch event {
                case .notification(let method, let params):
                    if method == "notifications/progress", let m = params["message"]?.string {
                        if let watched = self.progressWatch, params["progressToken"]?.string == watched {
                            self.ghidraProgress = m
                        } else {
                            self.note(m)
                        }
                    }
                    if method == "notifications/tools/list_changed", let tools = try? await client.listTools() {
                        self.tools = tools.sorted { $0.name < $1.name }
                    }
                case .exited(let status, let stderr):
                    if self.phase == .ready {
                        let tail = stderr.split(separator: "\n").suffix(3).joined(separator: " ")
                        self.phase = .failed("The engine stopped (exit \(status)). \(tail)")
                    }
                }
            }
        })
        // The inbox is a folder: read it off the main thread twice a second.
        let inbox = self.inbox
        watchers.append(Task { [weak self] in
            while !Task.isCancelled {
                let pending = await Task.detached { inbox.pending() }.value
                guard let self else { return }
                if pending != self.waiting { self.waiting = pending }
                try? await Task.sleep(for: .milliseconds(500))
            }
        })
    }

    static func failure(_ message: String) -> ToolResult {
        ToolResult(json: ["isError": true, "content": [["type": "text", "text": .string(JSONValue.object(["error": ["message": .string(message)]]).compact())]]])
    }
}
