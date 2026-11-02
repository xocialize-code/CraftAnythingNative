import Foundation

/// Something the engine is waiting on the person for: a question, or approval for an action.
/// It mirrors the engine's inbox files (`<id>.request.json`).
public struct InboxRequest: Sendable, Hashable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable { case question, approval }

    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String
    public var choices: [String]
    public var allowText: Bool
    /// For approvals: the action's kind, so "always allow" is remembered per kind.
    public var action: String?
    public var createdMs: UInt64

    enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, choices, action
        case allowText = "allow_text"
        case createdMs = "created_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        choices = try c.decodeIfPresent([String].self, forKey: .choices) ?? []
        allowText = try c.decodeIfPresent(Bool.self, forKey: .allowText) ?? false
        action = try c.decodeIfPresent(String.self, forKey: .action)
        createdMs = try c.decodeIfPresent(UInt64.self, forKey: .createdMs) ?? 0
    }
}

/// The person's answer (`<id>.answer.json`).
public struct InboxAnswer: Sendable, Hashable, Codable {
    public var choice: String?
    public var text: String?
    /// Approvals: true to allow.
    public var allow: Bool?
    /// Approvals: allow this kind of action for the rest of the project.
    public var always: Bool

    public init(choice: String? = nil, text: String? = nil, allow: Bool? = nil, always: Bool = false) {
        self.choice = choice
        self.text = text
        self.allow = allow
        self.always = always
    }

    public static func approve(always: Bool = false) -> InboxAnswer { InboxAnswer(allow: true, always: always) }
    public static let deny = InboxAnswer(allow: false)
}

/// The engine's inbox folder, which `craft-anything-cli mcp --inbox <dir>` posts to: the asker
/// writes `<id>.request.json` and waits; we write `<id>.answer.json`; the asker removes both.
public struct Inbox: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// Requests that have no answer yet, oldest first. Unreadable files are skipped.
    public func pending() -> [InboxRequest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let answered = Set(names.compactMap { $0.hasSuffix(".answer.json") ? String($0.dropLast(".answer.json".count)) : nil })
        let decoder = JSONDecoder()
        return names.compactMap { name -> InboxRequest? in
            guard name.hasSuffix(".request.json") else { return nil }
            let id = String(name.dropLast(".request.json".count))
            guard Self.isValid(id), !answered.contains(id),
                let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                let request = try? decoder.decode(InboxRequest.self, from: data), request.id == id
            else { return nil }
            return request
        }
        .sorted { ($0.createdMs, $0.id) < ($1.createdMs, $1.id) }
    }

    /// Answer a request. The file is written whole (temp file, then rename), so the engine never
    /// reads half an answer.
    public func answer(_ id: String, _ answer: InboxAnswer) throws {
        guard Self.isValid(id) else { throw EngineError("Not an inbox request id: \(id)") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(answer)
        let target = directory.appendingPathComponent("\(id).answer.json")
        let temp = directory.appendingPathComponent(".\(id).answer.\(UUID().uuidString).tmp")
        try data.write(to: temp)
        if rename(temp.path, target.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw EngineError("Couldn't save the answer: \(String(cString: strerror(code)))")
        }
    }

    /// The engine's rule for ids: 1–64 of `a-z`, `0-9` and `-`, so an id never leaves the folder.
    public static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 && id.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
    }
}
