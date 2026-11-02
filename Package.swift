// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CraftAnythingNative",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CraftEngineKit", targets: ["CraftEngineKit"]),
        .executable(name: "CraftAnythingNative", targets: ["CraftAnythingNative"]),
        .executable(name: "craft-anything-tool-server", targets: ["CraftAnythingToolServer"]),
        .executable(name: "craft-anything-native-tools", targets: ["CraftAnythingNativeTools"]),
    ],
    targets: [
        // The engine connection: the pinned craft-anything-cli's MCP server over stdio, its inbox,
        // and the tool server that stands in front of it for builders.
        .target(name: "CraftEngineKit"),
        // The SwiftUI shell.
        .executableTarget(name: "CraftAnythingNative", dependencies: ["CraftEngineKit"]),
        // What builders get as their tool server: the engine's, with native tools answering here.
        .executableTarget(name: "CraftAnythingToolServer", dependencies: ["CraftEngineKit"]),
        // Engine tools served natively: the website browser set with WebKit.
        .target(name: "CraftWebKit", dependencies: ["CraftEngineKit"]),
        // The plugin the engine sends those tools to (`[[plugins.mcp]]` with `replaces`).
        .executableTarget(name: "CraftAnythingNativeTools", dependencies: ["CraftEngineKit", "CraftWebKit"]),
        .testTarget(name: "CraftEngineKitTests", dependencies: ["CraftEngineKit", "CraftWebKit"]),
    ]
)
