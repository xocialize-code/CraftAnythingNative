import CraftEngineKit
import SwiftUI

/// Every tool the engine lists, with a form for its arguments built from its schema.
struct ToolsView: View {
    @Environment(EngineModel.self) private var engine
    @State private var search = ""
    @State private var selected: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Find a tool", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                list
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)

            Group {
                if let tool = engine.tools.first(where: { $0.name == selected }) {
                    ToolRunner(tool: tool).id(tool.name)
                } else {
                    ContentUnavailableView {
                        Label("Pick a tool", systemImage: "wrench.and.screwdriver")
                    } description: {
                        Text("\(engine.tools.count) tools in \(engine.cleanRoom ? "Clean room" : "Deep mode"). Each is also a CLI command and an MCP tool."
                            + (engine.cleanRoom ? " Deep mode adds the tools that look inside an original." : ""))
                    } actions: {
                        if engine.cleanRoom { DeepModeNeeded(explain: false) }
                    }
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Tools")
    }

    private var list: some View {
        List(selection: $selected) {
            ForEach(areas, id: \.self) { area in
                Section(area) {
                    ForEach(filtered.filter { $0.area == area }) { t in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title)
                            Text(t.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        .tag(t.name)
                    }
                }
            }
        }
    }

    private var filtered: [EngineTool] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return engine.tools }
        return engine.tools.filter { $0.name.contains(q) || $0.title.lowercased().contains(q) || $0.description.lowercased().contains(q) }
    }

    private var areas: [String] {
        Array(Set(filtered.map(\.area))).sorted()
    }
}

/// Fill in a tool's arguments and run it.
private struct ToolRunner: View {
    @Environment(EngineModel.self) private var engine
    let tool: EngineTool
    @State private var values: [String: String] = [:]
    @State private var flags: [String: Bool] = [:]
    @State private var running: Task<Void, Never>?
    @State private var result: ToolResult?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.title).font(.title2.bold())
                    Text(tool.name).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(tool.description).textSelection(.enabled)
                if !tool.parameters.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(tool.parameters) { p in field(p) }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    if let running {
                        Button("Stop") { running.cancel() }.keyboardShortcut(.cancelAction)
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Run", action: run).keyboardShortcut(.return, modifiers: .command)
                    }
                    if let problem { Text(problem).foregroundStyle(.red) }
                    Spacer()
                    if tool.readOnly { Text("Read-only").font(.caption).foregroundStyle(.secondary) }
                }
                if let result {
                    GroupBox(result.isError ? "Failed" : "Result") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let message = result.errorMessage { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                            if result.isCleanRoomRefusal {
                                if engine.cleanRoom { DeepModeNeeded() } else { Text("Deep mode is on now: run it again.").foregroundStyle(.secondary) }
                            }
                            Text(result.json.pretty())
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func field(_ p: ToolParameter) -> some View {
        let label = p.required ? "\(p.name) *" : p.name
        switch p.kind {
        case .boolean:
            Toggle(isOn: Binding(get: { flags[p.name] ?? false }, set: { flags[p.name] = $0 })) {
                Text(label).font(.callout.monospaced())
                Text(p.description)
            }
        case .choice(let options):
            Picker(selection: binding(p.name)) {
                Text("—").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            } label: {
                Text(label).font(.callout.monospaced())
                Text(p.description)
            }
        default:
            // Name and description above, the field below at full width: beside a long description
            // the field was squeezed to a sliver.
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.callout.monospaced())
                if !p.description.isEmpty { Text(p.description).font(.caption).foregroundStyle(.secondary) }
                TextField(label, text: binding(p.name), prompt: Text(prompt(p)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func prompt(_ p: ToolParameter) -> String {
        switch p.kind {
        case .integer, .number: "number"
        case .stringList: "one per line, or comma-separated"
        case .json: "JSON"
        default: ""
        }
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    /// The arguments as the schema wants them; nil (with `problem` set) when one doesn't fit.
    private func arguments() -> JSONValue? {
        var out: [String: JSONValue] = [:]
        for p in tool.parameters {
            if case .boolean = p.kind {
                if let f = flags[p.name] { out[p.name] = .bool(f) }
                continue
            }
            let raw = (values[p.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                if p.required { problem = "\(p.name) is needed."; return nil }
                continue
            }
            switch p.kind {
            case .integer:
                guard let n = Int(raw) else { problem = "\(p.name) takes a whole number."; return nil }
                out[p.name] = .number(Double(n))
            case .number:
                guard let n = Double(raw) else { problem = "\(p.name) takes a number."; return nil }
                out[p.name] = .number(n)
            case .stringList:
                let items = raw.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                out[p.name] = .array(items.map(JSONValue.string))
            case .json:
                guard let v = JSONValue.parse(raw) else { problem = "\(p.name) isn't valid JSON."; return nil }
                out[p.name] = v
            default:
                out[p.name] = .string(raw)
            }
        }
        return .object(out)
    }

    private func run() {
        problem = nil
        guard let args = arguments() else { return }
        result = nil
        running = Task {
            // Tools that run code wait for the person's approval in the app's inbox. Stop cancels
            // the call, and the engine is told to cancel it too.
            let r = await engine.call(tool.name, args, timeout: .seconds(45 * 60))
            if Task.isCancelled { problem = "Stopped." } else { result = r }
            running = nil
        }
    }
}
