import CraftEngineKit
import Foundation
import Observation

/// One line of a project's conversation, from `project_show`.
struct ConversationItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case person(String)
        case builder(String)
        case step(String)
        /// Tool calls the builder made: (name, succeeded).
        case work(notes: [String], tools: [ToolUse])
        case check(CheckResult)
        case other(String, String)
    }

    struct ToolUse: Hashable {
        var name: String
        var ok: Bool
    }

    var id: Int
    var kind: Kind

    init(id: Int, json: JSONValue) {
        self.id = id
        if let s = json["User"]?.string {
            kind = .person(s)
        } else if let a = json["Agent"] {
            kind = .builder(a["text"]?.string ?? "")
        } else if let s = json["Step"] {
            kind = .step(s["text"]?.string ?? "")
        } else if let w = json["Work"] {
            let tools = (w["tools"]?.array ?? []).compactMap { t -> ToolUse? in
                guard let pair = t.array, let name = pair.first?.string else { return nil }
                return ToolUse(name: name, ok: pair.dropFirst().first?.bool ?? true)
            }
            kind = .work(notes: w["notes"]?.array?.compactMap(\.string) ?? [], tools: tools)
        } else if let c = CheckResult(json: json["Check"]) {
            kind = .check(c)
        } else if let (key, value) = json.object?.first {
            kind = .other(key, value.string ?? value["text"]?.string ?? value.compact())
        } else {
            kind = .other("", json.compact())
        }
    }
}

/// A check's result.
struct CheckResult: Hashable {
    var check: String
    var passed: Bool
    var note: String
    var round: Int
    var artifacts: [String]

    init?(json: JSONValue?) {
        guard let json, let check = json["check"]?.string else { return nil }
        self.check = check
        passed = json["passed"]?.bool ?? false
        note = json["note"]?.string ?? ""
        round = json["round"]?.int ?? 0
        artifacts = json["artifacts"]?.array?.compactMap(\.string) ?? []
    }
}

/// What the app shows for the selected project, refreshed while it's on screen: often while a
/// build runs, now and then otherwise.
@MainActor @Observable
final class ProjectModel {
    let folder: String
    var name = ""
    var request = ""
    var stack = ""
    /// The browser that pictured the original website, for people; empty until it's studied.
    var browser = ""
    var statusLabel = ""
    var note = ""
    var running = false
    var queued: Int?
    var checks: [CheckResult] = []
    var questions: [InboxRequest] = []
    var conversation: [ConversationItem] = []
    var lastError: String?
    /// The last error was Clean room refusing something Deep mode would do.
    var refusedForCleanRoom = false
    /// The last error came from reading the project, not from something the person did, so the
    /// next good read clears it. An action's error stays until the next action.
    private var errorFromRefresh = false

    init(folder: String) { self.folder = folder }

    /// The engine records `built_in` (its own Chromium) or the id of the plugin that pictured the
    /// site; this app's plugin is `mac_app` (craft-anything-native-tools --print-config).
    static func browserName(_ recorded: String?) -> String {
        switch recorded {
        case nil: ""
        case "built_in": "Chromium"
        case "mac_app": "WebKit"
        case let other?: other
        }
    }

    var screenshot: URL? {
        let pictures = checks.reversed().flatMap(\.artifacts).filter { $0.hasSuffix(".png") }
        return pictures.first.map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
    }

    func refresh(_ engine: EngineModel) async {
        async let show = engine.call("project_show", ["project": .string(folder), "limit": 400])
        async let status = engine.call("rebuild_status", ["project": .string(folder)])
        let (s, st) = await (show, status)
        if let r = s.result {
            name = r["name"]?.string ?? URL(fileURLWithPath: folder).lastPathComponent
            request = r["request"]?.string ?? ""
            stack = r["stack"]?.string ?? ""
            browser = Self.browserName(r["browser"]?.string)
            checks = (r["checks"]?.array ?? []).compactMap(CheckResult.init(json:))
            questions = (r["questions"]?.array ?? []).compactMap(Self.request(from:))
            conversation = (r["conversation"]?["items"]?.array ?? []).enumerated().map { ConversationItem(id: $0.offset, json: $0.element) }
            if errorFromRefresh { failed(nil) }
        } else {
            failed(s)
            errorFromRefresh = true
        }
        if let r = st.result {
            let label = r["status_label"]?.string ?? ""
            note = r["note"]?.string ?? ""
            running = r["running"]?.bool ?? false
            queued = r["queued"]?.int
            // The sidebar lists every project's status from project_list; keep this one's current there.
            if label != statusLabel {
                statusLabel = label
                await engine.refreshProjects()
            }
        }
    }

    /// Keep refreshing until the task is cancelled (the view went away).
    func follow(_ engine: EngineModel) async {
        while !Task.isCancelled {
            await refresh(engine)
            try? await Task.sleep(for: running || queued != nil ? .seconds(2) : .seconds(10))
        }
    }

    func answer(_ q: InboxRequest, _ a: InboxAnswer, engine: EngineModel) async {
        var args: [String: JSONValue] = ["project": .string(folder), "id": .string(q.id), "always": .bool(a.always)]
        if let c = a.choice { args["choice"] = .string(c) }
        if let t = a.text, !t.isEmpty { args["text"] = .string(t) }
        if let allow = a.allow { args["allow"] = .bool(allow) }
        let r = await engine.call("project_inbox_answer", .object(args))
        failed(r)
        await refresh(engine)
    }

    /// Tell a running build something, or start a follow-up when none runs.
    func send(_ text: String, engine: EngineModel) async {
        let r: ToolResult
        if running {
            r = await engine.call("rebuild_note", ["project": .string(folder), "text": .string(text)])
        } else {
            // Starting a build needs the person's approval, which waits in the app's inbox.
            r = await engine.call("rebuild_start", ["project": .string(folder), "request": .string(text)], timeout: .seconds(45 * 60))
        }
        failed(r)
        await refresh(engine)
    }

    func stop(engine: EngineModel) async {
        failed(await engine.call("rebuild_stop", ["project": .string(folder)]))
        await refresh(engine)
    }

    func play(engine: EngineModel) async {
        failed(await engine.call("project_play", ["project": .string(folder)], timeout: .seconds(45 * 60)))
    }

    /// Keep what a call said when it failed, and whether Clean room was the reason.
    private func failed(_ r: ToolResult?) {
        lastError = r?.errorMessage
        refusedForCleanRoom = r?.isCleanRoomRefusal ?? false
        errorFromRefresh = false
    }

    private static func request(from json: JSONValue) -> InboxRequest? {
        try? JSONDecoder().decode(InboxRequest.self, from: Data(json.compact().utf8))
    }
}
