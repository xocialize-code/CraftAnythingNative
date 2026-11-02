import CraftEngineKit
import Foundation

/// The engine's website browser set, served with WebKit: `web_site_open`, `web_site_capture`,
/// `web_page_states_capture` and `web_site_close`, under the engine's own ids and arguments,
/// writing the same files. The engine sends them here when a plugin `replaces` them; they share one
/// browser, so they move together.
public enum WebKitBrowserTools {
    public static func all() -> [any NativeTool] {
        let site = SiteHolder()
        return [OpenTool(site: site), CaptureTool(site: site), StatesTool(site: site), CloseTool(site: site)]
    }

    static let product = "WebKit"

    static let webkitNote = ("webkit", "Pictured with WebKit (Safari's engine), not Chromium: compare it only with pictures WebKit took.")
}

/// The session's browser, made by `web_site_open` and dropped by `web_site_close`.
@MainActor
final class SiteHolder: Sendable {
    var browser: SiteBrowser?
    var url = ""
    var health: JSONValue = .null

    func open() -> SiteBrowser {
        if let browser { return browser }
        let b = SiteBrowser()
        browser = b
        return b
    }

    func close() -> Bool {
        guard let browser else { return false }
        browser.close()
        self.browser = nil
        return true
    }
}

/// What the engine read from the session for this call (`_meta`).
private func cleanRoom(_ meta: JSONValue) -> Bool { meta["clean_room"]?.bool ?? false }

private func run(_ body: @MainActor () async throws(ToolFailure) -> JSONValue) async -> JSONValue {
    do { return try await body() } catch { return Reply.failure(error) }
}

private func deadline(_ secs: Int) -> ContinuousClock.Instant {
    ContinuousClock.now + .seconds(max(secs, 1))
}

// MARK: web_site_open

struct OpenTool: NativeTool {
    let site: SiteHolder
    let name = "web_site_open"
    let description = "Load a web page in a private WebKit browser owned by this session and report its final address, title and size."

    func call(_ arguments: JSONValue, meta: JSONValue) async -> JSONValue {
        await run { @MainActor () async throws(ToolFailure) -> JSONValue in
            let a = try Arguments(arguments, allowed: ["url", "width", "height", "settle_ms", "headless", "timeout_secs"])
            let url = try checkURL(try a.string("url"))
            let (width, height) = (try a.int("width", 1440), try a.int("height", 900))
            guard (320...3840).contains(width), (320...4000).contains(height) else { throw .invalid("width must be 320..=3840 and height 320..=4000") }
            _ = try a.bool("headless", true)
            let dl = deadline(try a.int("timeout_secs", 90))
            let browser = site.open()
            var health = try await browser.load(url, width: width, height: height, settleMs: try a.int("settle_ms", 2000), deadline: dl)
            var facts = try await browser.evaluate(PageScripts.facts)
            let finalURL = facts["url"]?.string ?? url.absoluteString
            site.url = finalURL
            site.health = health
            // Clean room keeps what a visitor sees: not the load errors, failed requests or size in elements.
            if cleanRoom(meta) {
                if var f = facts.object { f.removeValue(forKey: "elements"); facts = .object(f) }
                health = .null
            }
            let hidden = try await browser.evaluate("document.visibilityState") == "hidden"
            let title = facts["title"]?.string ?? ""
            let shown = shownURL(finalURL)
            let opened = title.isEmpty ? "Opened \(shown)." : "Opened \(shown): \"\(title)\"."
            let (e, f) = (health["errors"]?.array?.count ?? 0, health["failed_requests"]?.array?.count ?? 0)
            let summary = e == 0 && f == 0 ? opened : "\(opened) While loading: \(e) error(s), \(f) failed request(s)."
            return Reply.evidence(
                subject: shown,
                result: ["url": .string(finalURL), "title": .string(title), "facts": facts, "health": health, "browser": .string(WebKitBrowserTools.product)],
                summary: summary,
                limitations: [("private_profile", "A fresh private browser: pages behind a login show their signed-out state."), WebKitBrowserTools.webkitNote]
                    + (hidden ? [("page_hidden", "The page believed it was hidden, so lazy pictures and animations may not have run.")] : []))
        }
    }
}

// MARK: web_site_capture

struct CaptureTool: NativeTool {
    let site: SiteHolder
    let name = "web_site_capture"
    let description = "Record the open website into a new folder: full-page screenshots at each width, design tokens, layout, outline and assets (capture.json, README.md)."

    static let maxHTMLBytes = 4 << 20

    func call(_ arguments: JSONValue, meta: JSONValue) async -> JSONValue {
        await run { @MainActor () async throws(ToolFailure) -> JSONValue in
            let a = try Arguments(arguments, allowed: ["output_directory", "widths", "max_height", "include_html", "noise_pass", "timeout_secs"])
            let widths = try a.ints("widths", [1440, 390])
            guard (1...4).contains(widths.count), widths.allSatisfy({ (320...3840).contains($0) }) else {
                throw .invalid("widths must hold 1..=4 values, each 320..=3840")
            }
            let maxHeight = try a.int("max_height", 12_000)
            guard (600...20_000).contains(maxHeight) else { throw .invalid("max_height must be 600..=20000") }
            let visitor = cleanRoom(meta)
            let includeHTML = try a.bool("include_html", true) && !visitor
            let noisePass = try a.bool("noise_pass", false)
            let dl = deadline(max(try a.int("timeout_secs", 90), 30))
            guard let browser = site.browser else { throw ToolFailure.noSite }
            let out = try createAbsentFolder(try a.string("output_directory"))

            var shots: [JSONValue] = [], layouts: [JSONValue] = []
            var blueprint: JSONValue = .null
            for (i, w) in widths.enumerated() {
                let view = await browser.present(width: w, height: 900)
                try await browser.pause(ms: 900, deadline: dl)
                // The blueprint is read at the first width, where the layout is the reference one.
                if i == 0 { blueprint = try await browser.evaluate(PageScripts.blueprint) }
                // A page whose layout can't be read is still photographed.
                if case .object(var layout)? = try? await browser.evaluate(PageScripts.layout) {
                    layout["width"] = .number(Double(w))
                    layouts.append(.object(layout))
                }
                // The page's height in CSS px, and the picture's (the same, unless a phone zooms out).
                let tall = try await browser.evaluate("Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)").uint
                let pictured = min(max(Int((Double(tall == 0 ? 900 : tall) * view.scale).rounded()), 320), maxHeight)
                let height = Int((Double(pictured) / view.scale).rounded())
                let first = try await browser.photograph(view, height: height)
                let file = "screenshot-\(w).png"
                try writeNew(first.png, named: file, in: out)
                var row: [String: JSONValue] = [
                    "file": .string(file), "width": .number(Double(first.image.width)), "height": .number(Double(first.image.height)),
                    "css_width": .number(Double(w)), "sha256": .string(sha256Hex(first.png)), "cut": .bool(pictured >= maxHeight),
                ]
                if noisePass {
                    // The same page twice more, at uneven gaps, so something repeating can't look still in both.
                    try await browser.pause(ms: 900, deadline: dl)
                    let second = try await browser.photograph(view, height: height)
                    try await browser.pause(ms: 1300, deadline: dl)
                    let third = try await browser.photograph(view, height: height)
                    let mask = NoiseMask(between: first.image, second.image, threshold: 24).union(NoiseMask(between: first.image, third.image, threshold: 24))
                    row["noise_tiles"] = .number(Double(mask.count))
                    if mask.count > 0, let png = mask.png() {
                        let noise = "noise-\(w).png"
                        try writeNew(png, named: noise, in: out)
                        row["noise_file"] = .string(noise)
                    }
                }
                shots.append(.object(row))
            }
            // Leave the page at the first (usually desktop) width for the tools that follow.
            _ = await browser.present(width: widths[0], height: 900)
            if case .object(var b) = blueprint {
                b["layouts"] = .array(layouts)
                blueprint = .object(b)
            }
            var htmlBytes = 0
            if includeHTML, let html = try await browser.evaluate("document.documentElement.outerHTML").string {
                // At most 4 MiB, cut at a whole character.
                var kept = Array(html.utf8.prefix(Self.maxHTMLBytes))
                while !kept.isEmpty, String(bytes: kept, encoding: .utf8) == nil { kept.removeLast() }
                htmlBytes = kept.count
                try writeNew(Data(kept), named: "page.html", in: out)
            }
            if visitor {
                blueprint = CaptureReport.visitorView(blueprint)
            } else if case .object(var b) = blueprint {
                b["health"] = site.health
                blueprint = .object(b)
            }
            try writeNew(Data(CaptureReport.readme(blueprint, shots: shots, htmlBytes: htmlBytes, visitor: visitor).utf8), named: "README.md", in: out)
            try writeNew(Data(blueprint.pretty().utf8), named: "capture.json", in: out)

            let url = blueprint["url"]?.string ?? ""
            let shown = shownURL(url)
            let n = { (k: String) in blueprint[k]?.array?.count ?? 0 }
            let images = blueprint.at("/assets/images")?.array?.count ?? 0
            let summary = "Captured \(shown): \(shots.count) screenshot(s), \(n("outline")) outline items, \(n("headings")) headings, \(images) images, \(n("links")) links, \(n("forms")) forms → \(out.path)."
            let counts: JSONValue = ["outline": .number(Double(n("outline"))), "headings": .number(Double(n("headings"))), "links": .number(Double(n("links"))),
                                     "forms": .number(Double(n("forms"))), "images": .number(Double(images))]
            return Reply.evidence(
                subject: shown,
                result: ["output_directory": .string(out.path), "url": .string(url), "title": blueprint["title"] ?? .null, "screenshots": .array(shots),
                         "html_bytes": .number(Double(htmlBytes)), "counts": counts, "design": blueprint["design"] ?? .null, "files": ["README.md", "capture.json"]],
                summary: summary,
                limitations: [
                    ("one_state", "One state of the page: menus, dialogs and content behind interactions are not opened."),
                    visitor
                        ? ("visitor_view", "Clean room: only what a visitor sees was kept (screenshots, visible text, measured layout and styles); not the page's HTML, CSS rules, scripts, requests or errors.")
                        : ("cross_origin_css", "CSS custom properties and breakpoints from cross-origin stylesheets can't be read."),
                    WebKitBrowserTools.webkitNote,
                ])
        }
    }
}

// MARK: web_page_states_capture

struct StatesTool: NativeTool {
    let site: SiteHolder
    let name = "web_page_states_capture"
    let description = "On the open website, open its menus, pop-ups, tabs and collapsed sections one at a time and picture each (states.json, state-<n>.png)."

    /// What a click changed, in plain words, from the state before and after.
    static func change(_ before: JSONValue, _ after: JSONValue) -> [String] {
        var out: [String] = []
        if after["expanded"] == "true" && before["expanded"] != "true" { out.append("expanded") }
        if after["selected"] == "true" && before["selected"] != "true" { out.append("tab selected") }
        if after["open"] == .bool(true) && before["open"] != .bool(true) { out.append("section opened") }
        if (after["dialogs"]?.uint ?? 0) > (before["dialogs"]?.uint ?? 0) { out.append("dialog appeared") }
        if after["url"] != before["url"] { out.append("address changed") }
        return out
    }

    func call(_ arguments: JSONValue, meta: JSONValue) async -> JSONValue {
        await run { @MainActor () async throws(ToolFailure) -> JSONValue in
            let a = try Arguments(arguments, allowed: ["output_directory", "max_states", "width", "timeout_secs"])
            let maxStates = try a.int("max_states", 4), width = try a.int("width", 1440)
            guard (1...8).contains(maxStates) else { throw .invalid("max_states must be 1..=8") }
            guard (320...3840).contains(width) else { throw .invalid("width must be 320..=3840") }
            let dl = deadline(max(try a.int("timeout_secs", 90), 30))
            guard let browser = site.browser else { throw ToolFailure.noSite }
            let out = try createAbsentFolder(try a.string("output_directory"))
            let find = PageScripts.findStates.replacingOccurrences(of: "__MAX__", with: String(maxStates))
            let state = { (i: String) in PageScripts.state.replacingOccurrences(of: "__I__", with: i) }
            let click = { (i: String) in PageScripts.clickState.replacingOccurrences(of: "__I__", with: i) }

            var view = await browser.present(width: width, height: 900)
            try await browser.pause(ms: 500, deadline: dl)
            let start = try await browser.evaluate("location.href").string ?? ""
            let found = try await browser.evaluate(find).array ?? []
            var states: [JSONValue] = []
            for (n, c) in found.enumerated() {
                if ContinuousClock.now >= dl { break }
                let i = String(c["index"]?.int ?? n)
                let before = try await browser.evaluate(state(i))
                guard try await browser.evaluate(click(i)) == .bool(true) else { continue }
                try await browser.pause(ms: 700, deadline: dl)
                let after = (try? await browser.evaluate(state(i))) ?? .null
                let changed = Self.change(before, after)
                var row: [String: JSONValue] = ["index": .number(Double(n)), "kind": c["kind"] ?? .null, "label": c["label"] ?? .null,
                                                "changed": .array(changed.map { .string($0) })]
                if !changed.contains("address changed") {
                    let shot = try await browser.photograph(view, height: Int((900 / view.scale).rounded()))
                    let file = "state-\(n + 1).png"
                    try writeNew(shot.png, named: file, in: out)
                    row["file"] = .string(file)
                    row["sha256"] = .string(sha256Hex(shot.png))
                }
                // Put the page back for the next one: close what opened, or go back to where it was.
                await browser.pressEscape()
                if let now = after["url"]?.string, now != start, let back = URL(string: start) {
                    _ = try await browser.load(back, width: width, height: 900, settleMs: 800, deadline: dl)
                    view = await browser.present(width: width, height: 900)
                    // The page reloaded: its marks are gone, so mark the toggles again.
                    _ = try? await browser.evaluate(find)
                } else if after["expanded"] == "true" || after["open"] == .bool(true) {
                    _ = try? await browser.evaluate(click(i))
                }
                try await browser.pause(ms: 300, deadline: dl)
                states.append(.object(row))
            }
            try writeNew(Data(JSONValue.object(["url": .string(start), "width": .number(Double(width)), "states": .array(states)]).pretty().utf8),
                         named: "states.json", in: out)
            let shown = shownURL(start)
            let pictured = states.filter { $0["file"] != nil }.count
            let summary = found.isEmpty
                ? "\(shown) has no menus, pop-ups, tabs or collapsed sections to open."
                : "Opened \(states.count) of \(found.count) control(s) on \(shown); \(pictured) pictured in \(out.path)."
            return Reply.evidence(
                subject: shown,
                result: ["url": .string(start), "found": .number(Double(found.count)), "states": .array(states), "folder": .string(out.path)],
                summary: summary,
                limitations: [
                    ("first_controls", "Only the first controls found are opened, one at a time; menus inside menus and hover-only menus are not."),
                    WebKitBrowserTools.webkitNote,
                ])
        }
    }
}

// MARK: web_site_close

struct CloseTool: NativeTool {
    let site: SiteHolder
    let name = "web_site_close"
    let description = "Close the private browser started by web_site_open."

    func call(_ arguments: JSONValue, meta: JSONValue) async -> JSONValue {
        await run { @MainActor () async throws(ToolFailure) -> JSONValue in
            _ = try Arguments(arguments, allowed: [])
            return Reply.value(["closed": .bool(site.close())])
        }
    }
}

extension PageScripts {
    /// What `web_site_open` reports about the page (the engine's `page_facts`).
    static let facts = """
        ({url: location.href, title: document.title, ready: document.readyState, lang: document.documentElement.lang || '', \
        width: document.documentElement.scrollWidth, height: document.documentElement.scrollHeight, \
        elements: document.getElementsByTagName('*').length, images: document.images.length, links: document.links.length, \
        forms: document.forms.length})
        """
}
