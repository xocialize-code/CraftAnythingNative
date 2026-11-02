# CraftAnythingNative

A native SwiftUI shell for Mac, built over a pinned Craft Anything engine. This is stage 1 of the plan in
`../craft-anything-swift-review.md`. The app starts our fork's `craft-anything-cli mcp` as a child process and
drives it the same way any MCP client would. No engine code is ported yet.

## Run it

```sh
Tools/engine/pin-engine.sh     # build the pinned engine into Engine/bin (needs the ../craft-anything clone at the pin)
swift build
.build/debug/CraftAnythingNative
```

`swift test` runs the engine-connection tests. When `Engine/bin` holds an engine, the tests also start it, list
its tools, call some of them, and check the approval round trip. They use temp folders for its settings and
projects.

To capture a window without the person's data, run with `--screenshot <file.png> [--section new|tools|<project folder>]`.
That draws the window into a PNG and quits. The engine's settings, projects and inbox go to a fresh temp folder.

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
- **`CraftAnythingNative`** is the app:
  - New Build: the request, the original (none, a website, or an app or file), the stack, and the number of
    rounds.
  - Projects: status, the conversation, questions to answer, checks, and the latest screenshot. From here you can
    send a note or a follow-up, stop the build, play the result, or show it in Finder.
  - A tool browser with a form for each tool, built from its schema.
  - A sheet for approvals posted to the app's inbox.

## The engine pin

`Tools/engine/pin.env` names the engine commit this shell drives: the `feature/swiftui-stack` branch of the
local fork, based on upstream `8c3532d`. We don't send changes upstream. Instead, we review what upstream adds
since the base and cherry-pick what's worth having. After that, move the pin, run `pin-engine.sh` and run the
tests again. `Engine/bin/pin.txt` records the binary's commit, version and sha256, and the toolbar shows that
commit.

The engine is storytold/craft-anything, MIT OR Apache-2.0. This shell uses none of its brand assets.

## Next (stage 2)

Port the pieces that are better native, behind the same tool ids:
- website capture and checks (WKWebView)
- window capture (ScreenCaptureKit)
- driving Claude Code, and the inbox
- project files, checked byte for byte against the pinned engine
