import AppKit
import CraftEngineKit
import SwiftUI

/// How this run was started: normally, or as a check that saves a picture of the window and quits.
struct LaunchOptions {
    var screenshot: URL?
    var section: SidebarItem = .newBuild

    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--screenshot": o.screenshot = it.next().map { URL(fileURLWithPath: $0) }
            case "--section":
                switch it.next() {
                case "tools": o.section = .tools
                case let p? where p.hasPrefix("/"): o.section = .project(p)
                default: o.section = .newBuild
                }
            default: break
            }
        }
        return o
    }
}

@main
struct CraftAnythingNativeApp: App {
    @State private var engine: EngineModel
    private let options = LaunchOptions.parse(CommandLine.arguments)

    init() {
        let options = LaunchOptions.parse(CommandLine.arguments)
        let fm = FileManager.default
        if options.screenshot != nil {
            // A check, not the person using the app: the engine's settings, projects and inbox go
            // to a fresh temp folder.
            let temp = fm.temporaryDirectory.appendingPathComponent("CraftAnythingNative-check-\(UUID().uuidString)")
            _engine = State(initialValue: EngineModel(inboxDir: temp.appendingPathComponent("inbox"), configDir: temp.appendingPathComponent("config")))
        } else {
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
            _engine = State(initialValue: EngineModel(inboxDir: support.appendingPathComponent("CraftAnythingNative/inbox")))
        }
        // Run straight from .build (not a bundled .app), the window and menu bar need this.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate()
    }

    var body: some Scene {
        WindowGroup("Craft Anything") {
            ContentView(initial: options.section)
                .environment(engine)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    await engine.start()
                    if let file = options.screenshot { await Screenshot.saveAndQuit(to: file, engine: engine) }
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Restart Engine") { Task { await engine.start() } }
            }
        }
    }
}

/// Saves the window to a PNG without asking for screen recording, then quits.
enum Screenshot {
    @MainActor
    static func saveAndQuit(to file: URL, engine: EngineModel) async {
        // Let the window draw what the engine loaded.
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView?.superview,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            FileHandle.standardError.write(Data("No window to save.\n".utf8))
            exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: file)) != nil else {
            FileHandle.standardError.write(Data("Couldn't save \(file.path).\n".utf8))
            exit(1)
        }
        await engine.stop()
        exit(0)
    }
}
