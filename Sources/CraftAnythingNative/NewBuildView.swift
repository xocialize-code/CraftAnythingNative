import AppKit
import CraftEngineKit
import SwiftUI

/// The stacks a build can be asked for by name: the engine's stacks.toml names (it takes an engine
/// or a stack's full name). Builder's choice sends none.
private let stacks = [
    "Swift + SwiftUI", "Electron", "Next.js + TypeScript", "React + TypeScript (Vite)", "Rust + egui (eframe)",
    "Rust (console)", "Rust + macroquad", "Python", "Godot", "Unity", "Unreal Engine",
]

/// Start a new project: what to make, what it's like, and what to build it with.
struct NewBuildView: View {
    enum Original: String, CaseIterable, Identifiable {
        case none = "Nothing"
        case website = "A website"
        case file = "An app or file"
        var id: String { rawValue }
    }

    @Environment(EngineModel.self) private var engine
    @Binding var selection: SidebarItem?
    @State private var request = ""
    @State private var original = Original.none
    @State private var address = ""
    @State private var path = ""
    @State private var stack = ""
    @State private var rounds = 2
    @State private var starting = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("What should it make?") {
                TextEditor(text: $request)
                    .font(.body)
                    .frame(minHeight: 90)
                    .overlay(alignment: .topLeading) {
                        if request.isEmpty {
                            Text("A notes app in SwiftUI, a snake game, a copy of this website…")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }
            Section("What is it like?") {
                Picker("Original", selection: $original) {
                    ForEach(Original.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch original {
                case .none:
                    Text("The builder works from your words alone.").foregroundStyle(.secondary)
                case .website:
                    TextField("Address", text: $address, prompt: Text("https://example.com"))
                case .file:
                    HStack {
                        TextField("Path", text: $path, prompt: Text("/Applications/Something.app"))
                        Button("Choose…", action: choose)
                    }
                }
            }
            Section("How") {
                Picker("Build with", selection: $stack) {
                    Text("Builder's choice").tag("")
                    Divider()
                    ForEach(stacks, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Refinement rounds: \(rounds)", value: $rounds, in: 0...6)
                LabeledContent("Saved in", value: engine.projectsDir.isEmpty ? "The engine's projects folder" : engine.projectsDir)
            }
            Section {
                HStack {
                    if starting {
                        ProgressView().controlSize(.small)
                        Text(engine.waiting.isEmpty ? "Starting…" : "Waiting for your approval…").foregroundStyle(.secondary)
                    }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    Spacer()
                    Button("Start Building", action: start)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canStart)
                }
            } footer: {
                Text("A coding agent (Claude Code, unless the engine's settings say otherwise) studies, builds, checks and refines in the background. It writes and runs code, so the engine asks you first.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New Build")
    }

    private var target: String? {
        switch original {
        case .none: return "-"
        case .website:
            let a = address.trimmingCharacters(in: .whitespaces)
            return a.isEmpty ? nil : a
        case .file:
            let p = path.trimmingCharacters(in: .whitespaces)
            return p.hasPrefix("/") ? p : nil
        }
    }

    private var canStart: Bool {
        !starting && target != nil && !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }

    private func start() {
        guard let target else { return }
        var args: [String: JSONValue] = [
            "request": .string(request.trimmingCharacters(in: .whitespacesAndNewlines)),
            "target": .string(target),
            "rounds": .number(Double(rounds)),
        ]
        if !stack.isEmpty { args["build_with"] = .string(stack) }
        starting = true
        error = nil
        Task {
            // The engine waits for the person's approval (in the app's inbox) before it starts.
            let r = await engine.call("rebuild_start", .object(args), timeout: .seconds(45 * 60))
            starting = false
            if let folder = r.result?["project"]?.string {
                await engine.refreshProjects()
                request = ""
                selection = .project(folder)
            } else {
                error = r.errorMessage ?? "The engine didn't say which project it started."
            }
        }
    }
}
