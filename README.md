# CraftAnythingNative

A native SwiftUI shell for Mac, built over a pinned Craft Anything engine. This is stage 1 of the plan in
`../craft-anything-swift-review.md`. The app starts our fork's `craft-anything-cli mcp` as a child process and
drives it the same way any MCP client would. No engine code is ported yet.

## Run it

```sh
Tools/engine/pin-engine.sh     # build the pinned engine into Engine/bin (needs the ../craft-anything clone at the pin)
swift build
.build/debug/CraftAnythingNative
Tools/make-app.sh              # or: a development app bundle with all three programs, at .build/CraftAnythingNative.app
```

`swift test` runs the engine-connection tests. When `Engine/bin` holds an engine, the tests also start it, list
its tools, call some of them, and check the approval round trip. They use temp folders for its settings and
projects.

To capture a window without the person's data, run with `--screenshot <file.png> [--section new|tools|<project folder>]`.
That draws the window into a PNG and quits. The engine's settings, projects and inbox go to a fresh temp folder.

## Releases

Pushing a `v<version>` tag that matches `VERSION` runs `.github/workflows/release.yml`, which runs
`Tools/release.sh` and publishes the GitHub Release. The release script:
- builds the pinned engine (from the private fork, through a read-only deploy key, `ENGINE_DEPLOY_KEY`)
- runs `swift test`
- bundles the app, the tool server, the WebKit plugin and the engine
- signs everything with Developer ID
- smoke-tests the bundle with the build folders hidden: the bundled engine serves the WebKit browser set through the
  bundled plugin, and the app draws its window
- notarizes and staples the app, then the DMG
- publishes the DMG, its `.sha256` and `Docs/releases/<version>.md` as the notes

The signing and notary secrets are organization secrets on xocialize-code, the same ones Gaea uses. Running the
workflow by hand (Actions › release › Run workflow) builds, checks and notarizes any ref without publishing.

The script runs the same way on this Mac: `Tools/release.sh` signs with the keychain's Developer ID, notarizes with
the `mlx-notary` profile when it exists, and leaves everything in `dist/`. `PUBLISH=yes` also publishes. Its header
lists the other settings, such as `SIGN_IDENTITY=-` for an ad hoc test build.

## What's here

- **`CraftEngineKit`** is the engine connection:
  - `MCPClient` is an actor that speaks newline-delimited JSON-RPC to the engine over stdio. Requests can
    overlap. Each request has a timeout and sends `notifications/cancelled` when it expires. The client drains
    stderr and keeps its last lines for error messages. If the engine stops, every waiting call fails with what
    it printed.
  - `Inbox` mirrors the engine's inbox folder. When the engine needs consent for an action (a build, Play), it
    posts the request there and waits, and the app writes the answer back as a whole file.
  - `EngineTool` and `ToolParameter` read the tools' JSON schemas, and `ToolResult` reads the engine's
    `{"result"}` / `{"error"}` replies.
  - `ToolServer` stands in front of the engine for the builders it starts. Every message passes through
    unchanged, except calls to a `NativeTool`, which are answered in Swift under the engine's own tool id.
  - `MCPServer` serves `NativeTool`s on their own, as an engine plugin.
- **`CraftWebKit`** is the engine's website browser set served with WebKit: `web_site_open`,
  `web_site_capture`, `web_page_states_capture` and `web_site_close`, under the engine's ids and arguments.
  They run the engine's own page scripts (`PageScripts.swift`, generated from the pin by
  `Tools/engine/sync-scripts.sh`) and write the same files: `screenshot-<width>.png`, `noise-<width>.png`,
  `capture.json`, `README.md`, `page.html`, `states.json` and `state-<n>.png`. Clean room comes from the call's
  `_meta`, as the engine sends it. The page runs in a private (non-persistent) WKWebView with light appearance and
  classic scrollbars, in a window nobody sees, at one pixel per CSS pixel. WebKit's window-occlusion check is
  turned off, so the page believes it's on screen (that switch isn't public API; without it the window is on
  screen but fully transparent, and the page is flagged if it still thinks it's hidden). Load errors are read
  from inside the page, so a failed request shows only when the browser reports it there.
- **`craft-anything-native-tools`** is the plugin the engine sends those tools to. In the engine's
  `config.toml` (`craft-anything-native-tools --print-config` prints the entry with its own path):

  ```toml
  [[plugins.mcp]]
  id = "mac_app"
  command = "/…/CraftAnythingNative.app/Contents/MacOS/craft-anything-native-tools"
  replaces = ["web_site_open", "web_site_capture", "web_page_states_capture", "web_site_close"]
  ```

  Every engine process reads it, so Study, the checks and the builders all picture websites with WebKit. Each
  project keeps the browser that pictured its original (`browser` in its `craft.json`, set by Study; the project
  screen shows it), and pictures of its build follow that record, so projects studied with Chromium stay on
  Chromium after WebKit is turned on. A project pictured with a plugin that's since been removed is refused, not
  switched; studying it again records the browser set up then. The app doesn't add the entry for you yet. Each call is logged to
  `~/Library/Logs/CraftAnythingNative/native-tools.log`. `Tools/parity/webkit-parity.py` captures the same pages
  both ways and reports the differences.
- **`craft-anything-tool-server`** is the program builders get as their tool server. The app sets
  `CRAFT_ANYTHING_TOOL_SERVER` (a patch in our fork) and `CRAFT_ANYTHING_ENGINE` in the engine's environment.
  `mcp …` is served through `ToolServer`; anything else (`builder-notes`) runs the engine itself. Each call is
  logged to `~/Library/Logs/CraftAnythingNative/tool-server.log`.
- **`CraftAnythingNative`** is the app:
  - New Build: the request, the original (none, a website, or an app or file), the stack, and the number of
    rounds.
  - Projects: status, the conversation, questions to answer, checks, and the latest screenshot. From here you can
    send a note or a follow-up, stop the build, play the result, or show it in Finder.
  - A tool browser with a form for each tool, built from its schema.
  - A sheet for approvals posted to the app's inbox.

## The engine pin

`Tools/engine/pin.env` names the engine commit this shell drives: the `native` branch of our fork (kept
private, at `xocialize/craft-anything`), based on upstream `8c3532d`. It adds the SwiftUI stack, the
`CRAFT_ANYTHING_TOOL_SERVER` setting, plugins that `replace` built-in tools (with the call's `_meta`), and the
website page scripts as files. We don't send changes upstream. Instead, we review what upstream adds
since the base and cherry-pick what's worth having. After that, move the pin, run `pin-engine.sh` and run the
tests again. `Engine/bin/pin.txt` records the binary's commit, version and sha256, and the toolbar shows that
commit.

## License

This shell is MIT (see `LICENSE`). The engine it drives is storytold/craft-anything, MIT OR Apache-2.0. This
shell uses none of its brand assets. `Sources/CraftWebKit/PageScripts.swift` holds a copy of the engine's
website page scripts, under the engine's license, as its header says.

## Next (stage 2)

Port the pieces that are better native, behind the same tool ids, as `NativeTool`s the engine sends to
`craft-anything-native-tools`:
- website capture (WKWebView): done, and each project keeps the browser that studied it
- window capture (ScreenCaptureKit)
- driving Claude Code, and the inbox
- project files, checked byte for byte against the pinned engine
