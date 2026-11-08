import Foundation

/// One tool the engine lists: its id, what it does, and the JSON Schema of its arguments.
public struct EngineTool: Sendable, Hashable, Identifiable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool
    public var destructive: Bool

    public var id: String { name }

    public init?(json: JSONValue) {
        guard let name = json["name"]?.string else { return nil }
        self.name = name
        title = json["title"]?.string ?? json["annotations"]?["title"]?.string ?? name
        description = json["description"]?.string ?? ""
        inputSchema = json["inputSchema"] ?? [:]
        readOnly = json["annotations"]?["readOnlyHint"]?.bool ?? false
        destructive = json["annotations"]?["destructiveHint"]?.bool ?? false
    }

    /// The tool's area, from its id (`core_target_open` → `core`).
    public var area: String { String(name.prefix(while: { $0 != "_" })) }

    /// Its arguments: required ones first, then by name.
    public var parameters: [ToolParameter] {
        let required = Set(inputSchema["required"]?.array?.compactMap(\.string) ?? [])
        let props = inputSchema["properties"]?.object ?? [:]
        return props.map { ToolParameter(name: $0.key, schema: $0.value, required: required.contains($0.key)) }
            .sorted { ($0.required ? 0 : 1, $0.name) < ($1.required ? 0 : 1, $1.name) }
    }
}

/// One argument of a tool, read from its JSON Schema.
public struct ToolParameter: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case string, integer, number, boolean
        case choice([String])
        case stringList
        /// Anything else (objects, mixed arrays): typed as JSON.
        case json
    }

    public var name: String
    public var schema: JSONValue
    public var required: Bool
    public var id: String { name }

    public var description: String { schema["description"]?.string ?? "" }

    public var kind: Kind {
        let s = schema["anyOf"]?.array?.first(where: { $0["type"]?.string != "null" }) ?? schema
        if let options = s["enum"]?.array?.compactMap(\.string), !options.isEmpty { return .choice(options) }
        if let ref = s["$ref"]?.string, ref.contains("#/") { return .json }
        let types = s["type"]?.array?.compactMap(\.string) ?? [s["type"]?.string].compactMap { $0 }
        switch types.first(where: { $0 != "null" }) {
        case "string": return .string
        case "integer": return .integer
        case "number": return .number
        case "boolean": return .boolean
        case "array" where s["items"]?["type"]?.string == "string": return .stringList
        default: return .json
        }
    }
}

/// What a tool call returned: the engine's `{"result": …}` or `{"error": …}` JSON.
public struct ToolResult: Sendable, Hashable {
    public var isError: Bool
    /// The whole JSON the tool returned (`result` or `error` at its top).
    public var json: JSONValue
    /// The text content, as sent.
    public var text: String

    public init(json reply: JSONValue) {
        isError = reply["isError"]?.bool ?? false
        text = (reply["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
        json = reply["structuredContent"] ?? JSONValue.parse(text) ?? .string(text)
    }

    /// The tool's result, when it succeeded.
    public var result: JSONValue? { isError ? nil : (json["result"] ?? json) }

    /// The failure in plain words, with what to do about it.
    public var errorMessage: String? {
        guard isError else { return nil }
        let err = json["error"] ?? json
        let message = err["message"]?.string ?? text
        if let fix = err["remediation"]?.string, !fix.isEmpty { return "\(message) \(fix)" }
        return message
    }

    /// The engine's error code (`not_found`, `consent_required`, …).
    public var errorCode: String? { isError ? json["error"]?["code"]?.string : nil }

    /// What the engine says about the failure beyond its message.
    public var errorDetails: JSONValue? { isError ? json["error"]?["details"] : nil }

    /// Clean room refused the tool because it looks inside the original; Deep mode would run it.
    public var isCleanRoomRefusal: Bool { errorDetails?["reason"]?.string == "clean_room" }
}
