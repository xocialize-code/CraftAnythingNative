// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CraftAnythingNative",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CraftEngineKit", targets: ["CraftEngineKit"]),
        .executable(name: "CraftAnythingNative", targets: ["CraftAnythingNative"]),
    ],
    targets: [
        // The engine connection: the pinned craft-anything-cli's MCP server over stdio, and its inbox.
        .target(name: "CraftEngineKit"),
        // The SwiftUI shell.
        .executableTarget(name: "CraftAnythingNative", dependencies: ["CraftEngineKit"]),
        .testTarget(name: "CraftEngineKitTests", dependencies: ["CraftEngineKit"]),
    ]
)
