import Foundation

/// A picture model Gaea offers for `image.generate`, as its MES descriptor lists it.
public struct GaeaPictureModel: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// The weights' licence (an SPDX id), as Gaea states it.
    public var licence: String
    /// Gaea runs it when a request names no model.
    public var isDefault: Bool
    /// It runs only when a request names it (research or opt-in models).
    public var namedOnly: Bool
}

/// Gaea, the media server on this Mac, as the engine reaches it: over the Media Engine Spec on
/// loopback. The app only asks what it offers; the engine sends the jobs.
public enum Gaea {
    /// Where Gaea serves MES by default: its port, and MES's base path.
    public static let defaultBase = "http://127.0.0.1:17630/mes/v0"

    /// The picture models Gaea at `base` offers, or nil when nothing answers there.
    public static func pictureModels(at base: String, timeout: TimeInterval = 3) async -> [GaeaPictureModel]? {
        let trimmed = base.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: (trimmed.isEmpty ? defaultBase : trimmed) + "/operations") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = JSONValue.parse(String(decoding: data, as: UTF8.self))
        else { return nil }
        return pictureModels(fromOperations: json)
    }

    /// The `image.generate` offers in a `GET /operations` answer: the default first, then by title.
    public static func pictureModels(fromOperations json: JSONValue) -> [GaeaPictureModel] {
        let generate = (json["operations"]?.array ?? []).first { $0["operation"]?.string == "image.generate" }
        let models = (generate?["models"]?.array ?? []).compactMap { m -> GaeaPictureModel? in
            guard let id = m["id"]?.string, !id.isEmpty else { return nil }
            return GaeaPictureModel(
                id: id, title: m["title"]?.string ?? id, licence: m["license"]?["spdx"]?.string ?? "",
                isDefault: m["default"]?.bool ?? false, namedOnly: m["named_only"]?.bool ?? false)
        }
        return models.sorted { ($0.isDefault ? 0 : 1, $0.title) < ($1.isDefault ? 0 : 1, $1.title) }
    }
}
