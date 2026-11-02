import AppKit
import CraftEngineKit
import WebKit

/// The session's website browser: one WKWebView in a borderless window nobody sees, with a private
/// (non-persistent) data store and light appearance, so captures don't depend on this computer's
/// sign-ins or theme. It stands in for the engine's private Chromium.
///
/// A page must believe it's on screen, or WebKit reports it `hidden` and stops drawing frames (lazy
/// pictures never load, animations stop), where headless Chromium always says `visible`. So the
/// window sits off every screen, where it draws at 1 CSS px per pixel as Chromium does, with
/// WebKit's window-occlusion check turned off. That switch isn't public API: where WebKit no longer
/// has it, the window is on screen instead, fully transparent, above other windows and ignoring the
/// mouse (it then draws at the screen's scale, and pictures are scaled back to CSS pixels).
@MainActor
final class SiteBrowser: NSObject, WKNavigationDelegate {
    private let window: NSWindow
    let web: WKWebView
    private var waiter: CheckedContinuation<NavigationEnd, Never>?
    /// Which wait a timeout belongs to, so an old one never ends a newer load's wait.
    private var waitNumber = 0
    /// The main document's own answer when it was 400 or more (Chromium's events report it too).
    private var documentFailure: JSONValue?

    enum NavigationEnd { case finished, failed(String), timedOut }

    /// Classic scrollbars, whatever this Mac is set to: a page that scrolls keeps a gutter, as in
    /// headless Chromium (15 px there, about 17 here), and captures don't change with whether a
    /// mouse is plugged in. Set where a launch argument would be, before the first web view.
    private static let scrollbars: Void = {
        UserDefaults.standard.setVolatileDomain(["AppleShowScrollBars": "Always"], forName: UserDefaults.argumentDomain)
    }()

    override init() {
        Self.scrollbars
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.inactiveSchedulingPolicy = .none
        config.userContentController.addUserScript(WKUserScript(source: Self.healthScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), configuration: config)
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        let offScreen = web.responds(to: occlusion)
        let origin: CGFloat = offScreen ? -30000 : 0
        window = NSWindow(contentRect: NSRect(x: origin, y: origin, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        if offScreen {
            web.perform(occlusion, with: false)
        } else {
            window.alphaValue = 0
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        }
        super.init()
        web.navigationDelegate = self
        web.appearance = NSAppearance(named: .aqua)
        web.autoresizingMask = [.width, .height]
        window.contentView = web
        window.orderFrontRegardless()
    }

    func close() {
        web.stopLoading()
        window.orderOut(nil)
        window.close()
    }

    /// The page's window size in CSS pixels.
    func resize(width: Int, height: Int) {
        window.setContentSize(NSSize(width: width, height: height))
        web.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    /// How the page is laid out at one width: `layout` CSS px wide, pictured `width` px wide.
    struct View: Equatable {
        var width: Int
        var layout: Int
        /// Pixels in the picture per CSS pixel of the page (below 1 for a phone zoomed out).
        var scale: Double { Double(width) / Double(layout) }
        /// The window's width: the layout plus a scrollbar gutter, when one is drawn.
        var frame: Int
    }

    /// Below this width the page is shown as on a phone, as the engine's Chromium does (`mobile`).
    static let phoneWidth = 600

    /// The layout width a phone gives a page whose viewport tag says `content`: its device width for
    /// `width=device-width`, a number it names, or 980 px with no tag (what phone browsers use).
    static func phoneLayout(width: Int, viewport content: String?) -> Int {
        guard let content else { return 980 }
        let parts = content.lowercased().split(whereSeparator: { $0 == "," || $0 == ";" })
        let value = parts.lazy.compactMap { p -> String? in
            let kv = p.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return kv.count == 2 && kv[0] == "width" ? kv[1] : nil
        }.first
        guard let value else { return width }
        if value == "device-width" { return width }
        guard let n = Double(value), n >= 1 else { return width }
        return min(max(Int(n), width), 10_000)
    }

    /// Lay the page out as a window `width` CSS px wide and `height` tall shows it. Under
    /// `phoneWidth` that's a phone: no scrollbar gutter (phones draw scrollbars over the page), and
    /// the layout width the page's viewport tag asks for, zoomed out to fit, with the window as tall
    /// as the phone's screen holds at that zoom.
    func present(width: Int, height: Int) async -> View {
        guard width < Self.phoneWidth else {
            resize(width: width, height: height)
            return View(width: width, layout: width, frame: width)
        }
        let tag = try? await evaluate("(document.querySelector('meta[name=\"viewport\" i]') || {}).content || null").string
        let layout = Self.phoneLayout(width: width, viewport: tag)
        let tall = Int((Double(height) * Double(layout) / Double(width)).rounded())
        resize(width: layout, height: tall)
        let gutter = (try? await evaluate("innerWidth - document.documentElement.clientWidth").int) ?? 0
        if gutter > 0 && gutter < 40 { resize(width: layout + gutter, height: tall) }
        return View(width: width, layout: layout, frame: layout + (gutter > 0 && gutter < 40 ? gutter : 0))
    }

    // MARK: Loading

    /// Open `url` at `width`×`height`, wait for the load (at most 45 s, or `deadline`), then let late
    /// content settle; returns what went wrong while it loaded (`errors`, `failed_requests`).
    func load(_ url: URL, width: Int, height: Int, settleMs: Int, deadline: ContinuousClock.Instant) async throws(ToolFailure) -> JSONValue {
        resize(width: width, height: height)
        documentFailure = nil
        finish(.timedOut)
        web.load(URLRequest(url: url))
        let limit = min(ContinuousClock.now + .seconds(45), deadline)
        switch await waitForLoad(until: limit) {
        case .failed(let why):
            throw ToolFailure(.programFailed, "the page didn't load: \(why)", remediation: "Check the address and your internet connection, then try again.")
        case .finished, .timedOut:
            break
        }
        try await pause(ms: min(settleMs, 30_000), deadline: deadline)
        return await health()
    }

    private func waitForLoad(until limit: ContinuousClock.Instant) async -> NavigationEnd {
        waitNumber += 1
        let number = waitNumber
        return await withCheckedContinuation { c in
            waiter = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(until: limit, clock: .continuous)
                if self?.waitNumber == number { self?.finish(.timedOut) }
            }
        }
    }

    private func finish(_ end: NavigationEnd) {
        waiter?.resume(returning: end)
        waiter = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.finished) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        // Committed, then stopped (a script stopped it, or a later failure): the page is there.
        finish(.finished)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        let e = error as NSError
        // A download or a page the view hands off isn't a load error worth stopping for.
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        finish(.failed(e.localizedDescription))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
            documentFailure = ["url": .string(shownURL(http.url?.absoluteString ?? "")), "status": .number(Double(http.statusCode)), "type": "Document"]
        }
        return .allow
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failed("the page's process stopped")) }

    /// Wait `ms`, but never past `deadline`; a stopped call ends here.
    func pause(ms: Int, deadline: ContinuousClock.Instant) async throws(ToolFailure) {
        let until = min(ContinuousClock.now + .milliseconds(max(ms, 0)), deadline)
        do { try await Task.sleep(until: until, clock: .continuous) } catch { throw ToolFailure(.cancelled, "stopped") }
        if ContinuousClock.now >= deadline { throw ToolFailure(.timedOut, "the website didn't finish in time", remediation: "Try again with a larger timeout_secs.") }
    }

    // MARK: Reading the page

    /// One of the engine's read-only page scripts (an expression), its JSON value. It runs in a
    /// world of its own: the page's scripts can't see or change it, though it reads the same DOM.
    func evaluate(_ script: String) async throws(ToolFailure) -> JSONValue {
        let value: Any?
        do {
            value = try await web.callAsyncJavaScript("return JSON.stringify(\(script)\n);", arguments: [:], in: nil, contentWorld: .defaultClient)
        } catch {
            let e = error as NSError
            let message = (e.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? e.localizedDescription
            throw ToolFailure(.programFailed, "reading the page failed: \(message.split(separator: "\n").first.map(String.init) ?? message)")
        }
        guard let text = value as? String else { return .null }
        guard let json = JSONValue.parse(text) else { throw ToolFailure(.garbledOutput, "the page's answer wasn't JSON") }
        return json
    }

    /// Our health script's findings from inside the page, plus the document's own failure.
    private func health() async -> JSONValue {
        let raw = try? await web.callAsyncJavaScript(
            "const h = window.__craftHealth; return JSON.stringify(h ? {errors: h.errors, failed: h.failed.concat(h.status()).slice(0, 50)} : null);",
            arguments: [:], in: nil, contentWorld: .page)
        let h = (raw as? String).flatMap(JSONValue.parse)
        var failed = h?["failed"]?.array ?? []
        if let documentFailure { failed.insert(documentFailure, at: 0) }
        let errors = (h?["errors"]?.array ?? []).map { e -> JSONValue in
            var o = e.object ?? [:]
            o["url"] = .string(shownURL(o["url"]?.string ?? ""))
            return .object(o)
        }
        return ["errors": .array(errors), "failed_requests": .array(Array(failed.prefix(50)))]
    }

    /// Wait until the page has drawn at its current size.
    func drawn() async {
        // Two frames, or a moment if frames aren't coming.
        _ = try? await web.callAsyncJavaScript("await new Promise(r => { requestAnimationFrame(() => requestAnimationFrame(r)); setTimeout(r, 250); }); return 1;",
                                               arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    /// A picture of the top `height` CSS pixels of the page as `view` lays it out, `view.width`
    /// pixels wide (a phone's zoomed-out layout is scaled down to fit).
    func photograph(_ view: View, height: Int) async throws(ToolFailure) -> (png: Data, image: RGBAImage) {
        if Int(web.frame.width) != view.frame || Int(web.frame.height) != height { resize(width: view.frame, height: height) }
        await drawn()
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: 0, y: 0, width: view.layout, height: height)
        cfg.snapshotWidth = NSNumber(value: view.layout)
        cfg.afterScreenUpdates = true
        let snapshot: NSImage
        do { snapshot = try await web.takeSnapshot(configuration: cfg) } catch {
            throw ToolFailure(.programFailed, "the browser couldn't take the picture: \(error.localizedDescription)")
        }
        let out = (width: view.width, height: max(Int((Double(height) * view.scale).rounded()), 1))
        guard let cg = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil), let image = RGBAImage(cg, width: out.width, height: out.height),
              let png = image.png() else { throw ToolFailure(.garbledOutput, "the browser returned no screenshot") }
        return (png, image)
    }

    /// Escape, as a person presses it: a key event to the page, and the same key dispatched in it
    /// (a view that isn't key may not pass the first one on).
    func pressEscape() async {
        window.makeFirstResponder(web)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                        isARepeat: false, keyCode: 53) {
                type == .keyDown ? web.keyDown(with: e) : web.keyUp(with: e)
            }
        }
        _ = try? await web.callAsyncJavaScript("""
            const t = document.activeElement || document.body || document.documentElement;
            for (const type of ['keydown', 'keyup']) t.dispatchEvent(new KeyboardEvent(type, {key: 'Escape', code: 'Escape', keyCode: 27, which: 27, bubbles: true, cancelable: true}));
            return 1;
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    /// Kept in the page from its first script on: uncaught errors, console errors and assertions,
    /// failed loads of pictures, scripts and styles, and (where the browser tells) answers of 400 or
    /// more. Texts are one line of 300 characters, each once; addresses lose their query strings.
    static let healthScript = #"""
    (() => {
      if (window.__craftHealth) return;
      const h = window.__craftHealth = {errors: [], failed: []};
      const line = s => String(s == null ? '' : s).split('\n')[0].slice(0, 300);
      const bare = u => String(u || '').split(/[?#]/)[0];
      const add = (kind, text, url) => { text = line(text); if (text && h.errors.length < 30 && !h.errors.some(e => e.text === text)) h.errors.push({kind, text, url: bare(url)}); };
      const kinds = {IMG: 'Image', SCRIPT: 'Script', LINK: 'Stylesheet', VIDEO: 'Media', AUDIO: 'Media', SOURCE: 'Media', IFRAME: 'Document'};
      addEventListener('error', e => {
        const t = e.target;
        if (t && t !== window && t.tagName) { if (h.failed.length < 50) h.failed.push({url: bare(t.currentSrc || t.src || t.href), error: 'load failed', type: kinds[t.tagName] || 'Other'}); return; }
        add('script', e.error && e.error.name ? e.error.name + ': ' + e.error.message : e.message, e.filename);
      }, true);
      addEventListener('unhandledrejection', e => add('script', 'Uncaught (in promise) ' + (e.reason && e.reason.message ? e.reason.message : e.reason), ''));
      const text = a => a.map(x => typeof x === 'string' ? x : x && x.message ? x.message : String(x)).join(' ');
      const err = console.error, as = console.assert;
      console.error = function (...a) { add('console', text(a), ''); return err.apply(this, a); };
      console.assert = function (c, ...a) { if (!c) add('console', text(a.length ? a : ['Assertion failed']), ''); return as.apply(this, [c, ...a]); };
      h.status = () => (performance.getEntriesByType ? performance.getEntriesByType('resource') : [])
        .filter(r => r.responseStatus >= 400).slice(0, 50)
        .map(r => ({url: bare(r.name), status: r.responseStatus, type: r.initiatorType === 'img' ? 'Image' : r.initiatorType === 'script' ? 'Script' : r.initiatorType === 'link' || r.initiatorType === 'css' ? 'Stylesheet' : r.initiatorType === 'fetch' ? 'Fetch' : r.initiatorType === 'xmlhttprequest' ? 'XHR' : 'Other'}));
    })();
    """#
}
