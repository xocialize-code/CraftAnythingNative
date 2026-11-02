import CraftEngineKit
import Foundation

/// The capture folder's README.md and the Clean room view of capture.json, written the way the
/// engine's `web_site_capture` writes them, so readers of either don't tell the browsers apart.
enum CaptureReport {
    /// Drop everything a visitor can't see: the page's metadata, CSS variables and breakpoints,
    /// the stylesheets, scripts, fonts and requests it loaded, and where its pictures come from
    /// (their sizes stay).
    static func visitorView(_ blueprint: JSONValue) -> JSONValue {
        guard var b = blueprint.object else { return blueprint }
        for k in ["meta", "breakpoints", "unreadable_stylesheets", "health"] { b.removeValue(forKey: k) }
        if var d = b["design"]?.object {
            d.removeValue(forKey: "css_variables")
            d.removeValue(forKey: "font_faces")
            b["design"] = .object(d)
        }
        let images = (b["assets"]?["images"]?.array ?? []).map { i -> JSONValue in ["w": i["w"] ?? .null, "h": i["h"] ?? .null] }
        b["assets"] = ["images": .array(images)]
        return .object(b)
    }

    static func readme(_ b: JSONValue, shots: [JSONValue], htmlBytes: Int, visitor: Bool) -> String {
        let s = { (p: String) in b.at(p)?.string ?? "" }
        let top = { (p: String, n: Int) in
            (b.at(p)?.array ?? []).prefix(n).compactMap { $0["value"]?.string }.map { "`\($0)`" }.joined(separator: ", ")
        }
        var md = "# Capture of \(shownURL(s("/url")))\n\n"
        md += "- Title: \(s("/title"))\n"
        if !s("/meta/description").isEmpty { md += "- Description: \(s("/meta/description"))\n" }
        md += "- Page size at the first width: \(b.at("/page/w")?.uint ?? 0)×\(b.at("/page/h")?.uint ?? 0) CSS px\n\n"
        md += "## Files\n\n"
        for sh in shots {
            let cut = sh["cut"]?.bool == true ? " (cut at the height limit)" : ""
            md += "- `\(sh["file"]?.string ?? "")` — \(sh["width"]?.uint ?? 0)×\(sh["height"]?.uint ?? 0) px screenshot\(cut)\n"
            if let noise = sh["noise_file"]?.string {
                md += "- `\(noise)` — the parts that changed by themselves between two photos a moment apart (white, one pixel per 16 px square): carousels, videos, animations. They aren't compared.\n"
            }
        }
        if htmlBytes > 0 { md += "- `page.html` — rendered HTML (\(htmlBytes) bytes)\n" }
        if visitor {
            md += "- `capture.json` — design tokens, the layout at each width (`layouts`), layout outline (positions in CSS px), headings, links, forms, picture sizes and visible text\n\n"
            md += "Clean room: only what a visitor sees was kept. The page's HTML, CSS rules, scripts, requests and errors weren't read.\n\n"
        } else {
            md += "- `capture.json` — design tokens, breakpoints, the layout at each width (`layouts`), layout outline (positions in CSS px), headings, links, forms, assets and visible text\n\n"
        }
        md += "## Design at a glance\n\n"
        md += "- Fonts: \(top("/design/fonts", 4))\n"
        md += "- Text sizes: \(top("/design/font_sizes", 8))\n"
        md += "- Text colours: \(top("/design/text_colors", 6))\n"
        md += "- Backgrounds: \(top("/design/backgrounds", 6))\n"
        md += "- Corner radii: \(top("/design/radii", 5))\n"
        md += "- Spacing (padding, gaps, margins): \(top("/design/spacing", 10))\n"
        md += "- Content widths: \(top("/design/max_widths", 4))\n"
        md += visitor ? "\n" : "- Font files: \(b.at("/assets/fonts")?.array?.count ?? 0)\n\n"
        md += layoutSection(b, visitor: visitor)
        if !visitor { md += healthSection(b) }
        md += "## Headings\n\n"
        for h in (b.at("/headings")?.array ?? []).prefix(40) {
            let level = max(h["level"]?.uint ?? 1, 1)
            md += String(repeating: "  ", count: level - 1) + "- \(h["text"]?.string ?? "")\n"
        }
        return md
    }

    private static func healthSection(_ b: JSONValue) -> String {
        let errors = b.at("/health/errors")?.array ?? [], failed = b.at("/health/failed_requests")?.array ?? []
        var md = "## Page health\n\n"
        if errors.isEmpty && failed.isEmpty {
            md += "It loaded without script errors or failed requests.\n\n"
        } else {
            for e in errors.prefix(10) { md += "- \(e["kind"]?.string ?? "script") error: \(e["text"]?.string ?? "")\n" }
            for f in failed.prefix(10) {
                let why = f["status"]?.int.map(String.init) ?? f["error"]?.string ?? ""
                md += "- failed request (\(why)): \(f["url"]?.string ?? "")\n"
            }
            md += "\n"
        }
        if let a = b["a11y"] {
            let lang = a["lang"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "not set"
            md += "## Accessibility\n\nLanguage: \(lang). Controls without a name: \(a["unnamed_controls"]?.uint ?? 0). Pictures without alt text: \(a["images_without_alt"]?.uint ?? 0).\n\n"
        }
        return md
    }

    private static func breakpointsSection(_ b: JSONValue) -> String {
        let bps = (b.at("/breakpoints")?.array ?? []).compactMap { $0["query"]?.string }
        let unreadable = b["unreadable_stylesheets"]?.uint ?? 0
        let body = switch (bps.isEmpty, unreadable) {
        case (true, 0): "Its CSS has no width breakpoints.\n\n"
        case (true, let u): "None readable: \(u) stylesheet(s) from other sites can't be read; compare the screenshots at each width.\n\n"
        case (false, _): "Its CSS switches layout at: \(bps.joined(separator: ", "))\n\n"
        }
        return "## Breakpoints\n\n\(body)"
    }

    private static func layoutSection(_ b: JSONValue, visitor: Bool) -> String {
        var md = visitor ? "" : breakpointsSection(b)
        md += "## Layout at each width\n\n"
        for l in b.at("/layouts")?.array ?? [] {
            let (w, pw) = (l["width"]?.uint ?? 0, l["page_w"]?.uint ?? 0)
            let ty = { (k: String) in l.at("/type/\(k)")?.uint ?? 0 }
            let scroll = pw > w + 1 ? "page \(pw) px wide, so it scrolls sideways" : "no sideways scroll"
            md += "### \(w) px (\(scroll))\n\nHeadings \(ty("h1"))/\(ty("h2"))/\(ty("h3")) px, text \(ty("body")) px.\n\n"
            for blk in (l["blocks"]?.array ?? []).prefix(16) { md += "- \(blockLine(blk))\n" }
            md += "\n"
        }
        return md
    }

    /// One section at one width: `section "Pricing": padding 96 32 96 32, gap 24, 3 per row, column 1280 px at x 80`.
    private static func blockLine(_ blk: JSONValue) -> String {
        var s = blk["tag"]?.string ?? "block"
        if let h = blk["heading"]?.string { s += " \"\(h)\"" }
        s += ": padding " + (blk["pad"]?.array ?? []).map { String($0.uint) }.joined(separator: " ")
        if let gap = blk["gap"]?.uint, gap > 0 { s += ", gap \(gap)" }
        if let per = blk["per_row"]?.uint, per > 1 { s += ", \(per) per row" }
        if let c = blk["column"] { s += ", column \(c["max_w"]?.uint ?? 0) px at x \(c["x"]?.uint ?? 0)" }
        if let bg = blk["background"]?.string { s += ", background \(bg)" }
        return s
    }
}
