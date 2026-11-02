import CraftEngineKit
import CryptoKit
import Foundation

/// A tool failure in the engine's own shape (its `ToolError`), so callers branch on the same codes.
public struct ToolFailure: Error, Sendable, Equatable {
    public enum Code: String, Sendable {
        case badInput = "bad_input", notFound = "not_found", programFailed = "program_failed", timedOut = "timed_out"
        case cancelled, fileError = "file_error", garbledOutput = "garbled_output", `internal`
    }

    public var code: Code
    public var message: String
    public var remediation: String?

    public init(_ code: Code, _ message: String, remediation: String? = nil) {
        self.code = code
        self.message = message
        self.remediation = remediation
    }

    static func invalid(_ message: String, remediation: String? = nil) -> ToolFailure {
        ToolFailure(.badInput, message, remediation: remediation)
    }

    static let noSite = ToolFailure(.notFound, "no website is open", remediation: "Open one first with web_site_open.")

    var category: String {
        switch code {
        case .badInput: "input"
        case .notFound: "missing"
        case .timedOut: "slow"
        case .cancelled: "stopped"
        default: "failed"
        }
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "code": .string(code.rawValue), "category": .string(category), "message": .string(message),
            "retryable": .bool(code == .timedOut || code == .cancelled),
        ]
        if let remediation { o["remediation"] = .string(remediation) }
        return .object(o)
    }
}

/// `tools/call` results in the shapes the engine reads back (`call_replacement` in the fork).
enum Reply {
    /// A plain value, as the engine's own MCP server sends one.
    static func value(_ v: JSONValue) -> JSONValue {
        let payload: JSONValue = ["result": v]
        return ["content": [["type": "text", "text": .string(payload.compact())]], "structuredContent": payload]
    }

    /// An evidence record; the engine records it under its own id.
    static func evidence(subject: String, result: JSONValue, summary: String, limitations: [(String, String)], targetContent: Bool = false) -> JSONValue {
        let record: JSONValue = [
            "subject": ["kind": "website", "name": .string(subject)],
            "result": result,
            "summary": .string(summary),
            "confidence": "observed",
            "limitations": .array(limitations.map { ["code": .string($0.0), "message": .string($0.1)] }),
            "carries_target_content": .bool(targetContent),
        ]
        return ["content": [["type": "text", "text": .string(summary)]], "structuredContent": record]
    }

    static func failure(_ f: ToolFailure) -> JSONValue {
        ["content": [["type": "text", "text": .string(f.json.compact())]], "structuredContent": f.json, "isError": true]
    }
}

/// A tool's arguments, read the way the engine reads them: unknown fields are refused.
struct Arguments {
    private let o: [String: JSONValue]

    init(_ v: JSONValue, allowed: Set<String>) throws(ToolFailure) {
        let o = v.object ?? [:]
        if case .null = v {} else if v.object == nil { throw .invalid("the arguments must be an object") }
        if let extra = o.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw .invalid(allowed.isEmpty ? "unknown field `\(extra)`, there are no fields" : "unknown field `\(extra)`, expected one of \(allowed.sorted().map { "`\($0)`" }.joined(separator: ", "))")
        }
        self.o = o
    }

    func string(_ k: String) throws(ToolFailure) -> String {
        guard let s = o[k]?.string else { throw .invalid("missing field `\(k)`") }
        return s
    }

    func int(_ k: String, _ fallback: Int) throws(ToolFailure) -> Int {
        guard let v = o[k], !(v == .null) else { return fallback }
        guard let n = v.int, n >= 0 else { throw .invalid("`\(k)` must be a whole number") }
        return n
    }

    func bool(_ k: String, _ fallback: Bool) throws(ToolFailure) -> Bool {
        guard let v = o[k], !(v == .null) else { return fallback }
        guard let b = v.bool else { throw .invalid("`\(k)` must be true or false") }
        return b
    }

    func ints(_ k: String, _ fallback: [Int]) throws(ToolFailure) -> [Int] {
        guard let v = o[k], !(v == .null) else { return fallback }
        guard let a = v.array, let ns = Optional(a.compactMap { $0.int.flatMap { $0 >= 0 ? $0 : nil } }), ns.count == a.count else {
            throw .invalid("`\(k)` must be a list of whole numbers")
        }
        return ns
    }
}

/// A web address as shown in evidence and summaries: no credentials, query or fragment.
func shownURL(_ url: String) -> String {
    guard var c = URLComponents(string: url) else { return url.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? "" }
    c.user = nil
    c.password = nil
    c.query = nil
    c.fragment = nil
    return c.string ?? url
}

/// Only http(s) pages; never local files or browser-internal schemes (as the engine checks).
func checkURL(_ url: String) throws(ToolFailure) -> URL {
    let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let rest = u.hasPrefix("https://") ? u.dropFirst(8) : u.hasPrefix("http://") ? u.dropFirst(7) : nil
    guard let rest, !rest.isEmpty, !rest.hasPrefix("/"), !u.contains(where: \.isWhitespace), let parsed = URL(string: u) else {
        throw .invalid("\"\(url)\" is not a web address", remediation: "Give a full address such as https://example.com.")
    }
    return parsed
}

/// A folder that doesn't exist yet, inside one that does (as the engine's `create_absent_dir`).
func createAbsentFolder(_ path: String) throws(ToolFailure) -> URL {
    guard path.hasPrefix("/") else { throw .invalid("output_directory must be an absolute path") }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let fm = FileManager.default
    if (try? fm.attributesOfItem(atPath: url.path)) != nil {
        throw .invalid("\(url.path) already exists", remediation: "Choose a folder that does not exist yet; it will be created.")
    }
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDir), isDir.boolValue else {
        throw .invalid("\(url.deletingLastPathComponent().path) does not exist")
    }
    do { try fm.createDirectory(at: url, withIntermediateDirectories: false) } catch {
        throw ToolFailure(.fileError, "couldn't create \(url.path): \(error.localizedDescription)")
    }
    return url
}

/// Write a new file (never over one) in `folder`.
func writeNew(_ data: Data, named name: String, in folder: URL) throws(ToolFailure) {
    guard !name.contains("/"), name != "..", name != "." else { throw .invalid("unsafe file name \(name)") }
    let url = folder.appendingPathComponent(name)
    do { try data.write(to: url, options: .withoutOverwriting) } catch {
        throw ToolFailure(.fileError, "couldn't write \(url.path): \(error.localizedDescription)")
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

extension JSONValue {
    /// The value at a JSON pointer (`/design/fonts`), or nil.
    func at(_ pointer: String) -> JSONValue? {
        var cur: JSONValue? = self
        for part in pointer.split(separator: "/", omittingEmptySubsequences: true) {
            let key = String(part)
            if let a = cur?.array, let i = Int(key) { cur = i < a.count ? a[i] : nil } else { cur = cur?[key] }
        }
        return cur
    }

    /// A whole number, from a number that holds one.
    var uint: Int { int.map { max($0, 0) } ?? Int(max(number ?? 0, 0)) }
}
