import CraftEngineKit
import SwiftUI

/// What Deep mode means, said where the person turns it on.
private let deepMeaning = """
    Deep mode reads inside the originals you point Craft Anything at: a program's code and files (with Ghidra when it's \
    installed) and a website's HTML, scripts and requests. Builders get every tool. It's for your private use, on \
    things you may look inside.
    """

/// Asks before Deep mode goes on, switches the mode, and says when switching failed. Set `want` to
/// true to ask for Deep mode, or to false to go back to Clean room (that needs no asking).
private struct ModeSwitching: ViewModifier {
    @Environment(EngineModel.self) private var engine
    @Binding var want: Bool?
    @State private var failed: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Turn on Deep mode?", isPresented: asking, titleVisibility: .visible) {
                Button("Turn On Deep Mode") { change(to: true) }
                Button("Stay in Clean Room", role: .cancel) { want = nil }
            } message: {
                Text(engine.ghidraPath == nil
                    ? deepMeaning + "\n\nGhidra isn't on this Mac yet, so the built-in decompiler stands in. You can get Ghidra in Settings."
                    : deepMeaning)
            }
            .onChange(of: want) { _, next in
                if next == false { change(to: false) }
            }
            .alert("The mode didn't change", isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } })) {
                Button("OK") { failed = nil }
            } message: {
                Text(failed ?? "")
            }
    }

    private var asking: Binding<Bool> {
        Binding(get: { want == true }, set: { if !$0, want == true { want = nil } })
    }

    private func change(to on: Bool) {
        want = nil
        guard on == engine.cleanRoom else { return }
        Task { failed = await engine.setDeepMode(on) }
    }
}

extension View {
    /// See `ModeSwitching`.
    func modeSwitching(_ want: Binding<Bool?>) -> some View { modifier(ModeSwitching(want: want)) }
}

/// Clean room or Deep, in the toolbar: the mode for everything the engine does.
struct ModeToolbarControl: View {
    @Environment(EngineModel.self) private var engine
    @State private var want: Bool?

    var body: some View {
        Picker("Mode", selection: Binding(get: { !engine.cleanRoom }, set: { want = $0 })) {
            Label("Clean Room", systemImage: "checkmark.shield").tag(false)
            Label("Deep", systemImage: "magnifyingglass").tag(true)
        }
        .pickerStyle(.segmented)
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .disabled(engine.phase != .ready || engine.switchingMode)
        .help(engine.cleanRoom
            ? "Clean room: nothing inside an original is read. Craft Anything works from what you can see."
            : "Deep mode: Craft Anything reads an original's code and files with every tool it has.")
        .modeSwitching($want)
    }
}

/// The Clean room / Deep choice as two described options, for a form.
struct ModeChoice: View {
    @Environment(EngineModel.self) private var engine
    @State private var want: Bool?

    var body: some View {
        Picker("Mode", selection: Binding(get: { !engine.cleanRoom }, set: { want = $0 })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clean room")
                Text("Nothing inside it is read; Craft Anything works from what you can see. Your version gets its own art.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tag(false)
            VStack(alignment: .leading, spacing: 2) {
                Text("Deep")
                Text("Craft Anything reads its code and files with every tool it has. For your private use.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tag(true)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .disabled(engine.phase != .ready || engine.switchingMode)
        .modeSwitching($want)
    }
}

/// Whether Deep mode has Ghidra to read programs with, and a way to get it.
struct GhidraLine: View {
    @Environment(EngineModel.self) private var engine
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = engine.ghidraPath {
                Label("Ghidra reads programs for Deep mode's decompiled code.", systemImage: "cpu")
                    .help(path)
            } else if engine.installingGhidra {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progress).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Label("Ghidra isn't on this Mac yet, so the built-in decompiler stands in.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    if engine.ghidraInstallable {
                        Spacer()
                        Button("Get Ghidra") { Task { failed = await engine.installGhidra() } }
                    }
                }
            }
            if let failed { Text(failed).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    private var progress: String {
        if !engine.waiting.isEmpty { return "Waiting for your approval in the Craft Anything window…" }
        return engine.ghidraProgress.isEmpty ? "Getting Ghidra…" : engine.ghidraProgress
    }
}

/// Shown where Clean room refused something: what it means, and the way out.
struct DeepModeNeeded: View {
    @Environment(EngineModel.self) private var engine
    /// Say what Clean room didn't do; leave it out where the text around already says it.
    var explain = true
    @State private var want: Bool?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if explain {
                Text("Clean room never reads the original's code, files or page source. Deep mode does.")
                    .foregroundStyle(.secondary)
            }
            Button("Turn On Deep Mode") { want = true }
                .disabled(!engine.cleanRoom || engine.switchingMode)
        }
        .modeSwitching($want)
    }
}

/// The app's Settings window.
struct SettingsView: View {
    @Environment(EngineModel.self) private var engine

    var body: some View {
        Form {
            Section {
                ModeChoice()
            } header: {
                Text("Clean room or Deep")
            } footer: {
                Text("Saved in the engine's settings, so Study, the checks and the builders all follow it. Clean room is a rule about what Craft Anything reads, not a sandbox: a coding agent still acts as you.")
                    .foregroundStyle(.secondary)
            }
            Section("Ghidra") {
                GhidraLine()
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .disabled(engine.phase != .ready)
        .task { if engine.phase == .ready { await engine.refreshSettings() } }
    }
}
