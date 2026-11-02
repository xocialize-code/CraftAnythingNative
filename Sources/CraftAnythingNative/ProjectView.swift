import AppKit
import CraftEngineKit
import SwiftUI

/// One project: where its build stands, what it's asking, its latest picture and its conversation.
struct ProjectView: View {
    @Environment(EngineModel.self) private var engine
    @State private var model: ProjectModel
    @State private var message = ""
    @State private var busy = false

    init(folder: String) {
        _model = State(initialValue: ProjectModel(folder: folder))
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                conversation
                Divider()
                composer
            }
            .frame(minWidth: 420)
            side
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
        }
        .navigationTitle(model.name.isEmpty ? "Project" : model.name)
        .toolbar {
            ToolbarItemGroup {
                Button("Play", systemImage: "play.fill") { act { await model.play(engine: engine) } }
                    .help("Start the app or game it built")
                Button("Stop Build", systemImage: "stop.fill") { act { await model.stop(engine: engine) } }
                    .disabled(!model.running && model.queued == nil)
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.folder)])
                }
            }
        }
        .task { await model.follow(engine) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if model.running { ProgressView().controlSize(.small) }
                    Text(model.statusLabel.isEmpty ? "…" : model.statusLabel).font(.headline)
                    if let q = model.queued { Text("Queued (\(q))").foregroundStyle(.secondary) }
                    if !model.stack.isEmpty { Text(model.stack).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule()) }
                }
                if !model.note.isEmpty { Text(model.note).foregroundStyle(.secondary).textSelection(.enabled) }
                if let e = model.lastError { Text(e).foregroundStyle(.red).textSelection(.enabled) }
            }
            Spacer()
        }
        .padding(12)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.conversation) { item in
                        ConversationRow(item: item).id(item.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.conversation.count) {
                if let last = model.conversation.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack {
            TextField(model.running ? "Tell the builder something…" : "Ask for a change…", text: $message, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(send)
            Button(model.running ? "Send" : "Start Change", action: send)
                .disabled(busy || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    private var side: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !model.questions.isEmpty {
                    GroupBox("Waiting for you") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.questions) { q in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(q.title).font(.callout.bold())
                                    if !q.detail.isEmpty { Text(q.detail).font(.caption).foregroundStyle(.secondary) }
                                    if q.kind == .approval {
                                        HStack {
                                            Button("Deny") { act { await model.answer(q, .deny, engine: engine) } }
                                            Button("Allow") { act { await model.answer(q, .approve(), engine: engine) } }
                                        }
                                    } else {
                                        QuestionAnswerControls(request: q) { a in act { await model.answer(q, a, engine: engine) } }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let shot = model.screenshot, let image = NSImage(contentsOf: shot) {
                    GroupBox("Latest picture") {
                        Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                if !model.checks.isEmpty {
                    GroupBox("Checks") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(model.checks.suffix(8).enumerated()), id: \.offset) { _, c in
                                HStack(alignment: .top) {
                                    Image(systemName: c.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(c.passed ? .green : .red)
                                    VStack(alignment: .leading) {
                                        Text("\(c.check) · round \(c.round)").font(.caption.bold())
                                        Text(c.note).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !model.request.isEmpty {
                    GroupBox("Asked for") { Text(model.request).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                }
            }
            .padding(12)
        }
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        message = ""
        act { await model.send(text, engine: engine) }
    }

    private func act(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work()
            busy = false
            await engine.refreshProjects()
        }
    }
}

private struct ConversationRow: View {
    let item: ConversationItem

    var body: some View {
        switch item.kind {
        case .person(let text):
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
            }
        case .builder(let text):
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .step(let text):
            Label(text, systemImage: "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .work(let notes, let tools):
            WorkRow(notes: notes, tools: tools)
        case .check(let c):
            Label("\(c.check): \(c.note)", systemImage: c.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(c.passed ? Color.secondary : Color.red)
        case .other(let kind, let text):
            Text(kind.isEmpty ? text : "\(kind): \(text)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
    }
}

/// The tool calls of one stretch of the builder's work, folded to a line.
private struct WorkRow: View {
    let notes: [String]
    let tools: [ConversationItem.ToolUse]
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(notes, id: \.self) { Text($0).font(.caption) }
                ForEach(Array(tools.enumerated()), id: \.offset) { _, t in
                    Label(t.name, systemImage: t.ok ? "checkmark" : "xmark")
                        .font(.caption.monospaced())
                        .foregroundStyle(t.ok ? Color.secondary : Color.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            let failed = tools.filter { !$0.ok }.count
            Text("\(tools.count) step\(tools.count == 1 ? "" : "s")\(failed > 0 ? " · \(failed) failed" : "")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
