import CraftEngineKit
import SwiftUI

enum SidebarItem: Hashable {
    case newBuild
    case project(String)
    case tools
}

struct ContentView: View {
    @Environment(EngineModel.self) private var engine
    @State private var selection: SidebarItem?

    init(initial: SidebarItem) {
        _selection = State(initialValue: initial)
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            switch engine.phase {
            case .starting:
                ProgressView("Starting the engine…")
            case .failed(let why):
                EngineFailedView(message: why)
            case .ready:
                switch selection ?? .newBuild {
                case .newBuild: NewBuildView(selection: $selection)
                case .project(let folder): ProjectView(folder: folder).id(folder)
                case .tools: ToolsView()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .status) { EngineBadge() }
            ToolbarItem(placement: .primaryAction) { ModeToolbarControl() }
        }
        .sheet(item: Binding(get: { engine.waiting.first }, set: { _ in })) { request in
            InboxRequestView(request: request) { answer in engine.answer(request, answer) }
        }
    }
}

private struct Sidebar: View {
    @Environment(EngineModel.self) private var engine
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("New Build", systemImage: "plus.square.on.square").tag(SidebarItem.newBuild)
                Label("Tools", systemImage: "wrench.and.screwdriver").tag(SidebarItem.tools)
            }
            Section("Projects") {
                if engine.projects.isEmpty {
                    Text(engine.phase == .ready ? "None yet" : "…").foregroundStyle(.secondary)
                }
                ForEach(engine.projects) { p in
                    ProjectRow(project: p).tag(SidebarItem.project(p.folder))
                }
            }
        }
        .listStyle(.sidebar)
        .refreshable { await engine.refreshProjects() }
    }
}

private struct ProjectRow: View {
    let project: ProjectSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(project.name).lineLimit(1)
                if project.waiting > 0 {
                    Spacer()
                    Text("\(project.waiting)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            Text(project.statusLabel.isEmpty ? project.stack : "\(project.statusLabel) · \(project.stack)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct EngineBadge: View {
    @Environment(EngineModel.self) private var engine

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .help(engine.enginePath)
    }

    private var color: Color {
        switch engine.phase {
        case .starting: .yellow
        case .ready: .green
        case .failed: .red
        }
    }

    private var label: String {
        switch engine.phase {
        case .starting: return "Starting engine…"
        case .failed: return "Engine stopped"
        case .ready:
            let commit = engine.pin["commit"].map { " · \($0.prefix(7))" } ?? ""
            return "Engine \(engine.engineVersion)\(commit) · \(engine.tools.count) tools"
        }
    }
}

private struct EngineFailedView: View {
    @Environment(EngineModel.self) private var engine
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("The engine isn't running", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message).textSelection(.enabled)
        } actions: {
            Button("Start Again") { Task { await engine.start() } }
        }
    }
}

/// An approval or question the engine posted to the app's inbox.
struct InboxRequestView: View {
    let request: InboxRequest
    let answer: (InboxAnswer) -> Void
    @State private var always = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(request.kind == .approval ? "Approval needed" : "Question", systemImage: request.kind == .approval ? "hand.raised" : "questionmark.bubble")
                .font(.headline)
            Text(request.title).font(.title3)
            if !request.detail.isEmpty {
                ScrollView { Text(request.detail).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 220)
            }
            if request.kind == .approval {
                if request.action != nil { Toggle("Always allow this kind of action for this project", isOn: $always) }
                HStack {
                    Spacer()
                    Button("Deny", role: .cancel) { answer(.deny) }
                    Button("Allow") { answer(.approve(always: always)) }.keyboardShortcut(.defaultAction)
                }
            } else {
                QuestionAnswerControls(request: request, answer: answer)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// Buttons for a question's choices, and a text field when it takes typed answers.
struct QuestionAnswerControls: View {
    let request: InboxRequest
    let answer: (InboxAnswer) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !request.choices.isEmpty {
                FlowButtons(choices: request.choices) { answer(InboxAnswer(choice: $0, text: text.isEmpty ? nil : text)) }
            }
            if request.allowText || request.choices.isEmpty {
                HStack {
                    TextField("Your answer", text: $text).textFieldStyle(.roundedBorder).onSubmit(send)
                    Button("Send", action: send).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { answer(InboxAnswer(text: t)) }
    }
}

private struct FlowButtons: View {
    let choices: [String]
    let pick: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { buttons }
            VStack(alignment: .leading) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(choices, id: \.self) { c in Button(c) { pick(c) } }
    }
}
