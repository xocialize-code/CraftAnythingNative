import CraftEngineKit
import SwiftUI

/// The picture models in the engine's asset table, by id, as the person chooses between them.
let pictureModels: [(id: String, label: String)] = [
    ("gaea", "Gaea, on this Mac (free)"),
    ("nano-banana-pro", "fal.ai · Nano Banana Pro ($0.15 a picture)"),
    ("flux-dev", "fal.ai · FLUX.1 [dev] (about $0.03)"),
    ("flux-schnell", "fal.ai · FLUX.1 [schnell] (under $0.01)"),
]

/// Settings › Game assets: who makes a game's pictures (Gaea or fal.ai), which of Gaea's models,
/// and the fal.ai key that 3D models need.
struct GameAssetsSettings: View {
    @Environment(EngineModel.self) private var engine
    @State private var key = ""
    @State private var failed: String?
    @State private var busy = false

    var body: some View {
        Section {
            Picker("Pictures", selection: setting(\.imageModel, "image_model")) {
                ForEach(pictureModels, id: \.id) { Text($0.label).tag($0.id) }
            }
            // A grouped form's row label doesn't reach accessibility on its own.
            .accessibilityLabel("Pictures")
            if engine.imageModel == "gaea" { gaea }
        } header: {
            Text("Game assets")
        } footer: {
            Text("Used only for games whose builder you let generate assets (New Build › Game assets).")
                .foregroundStyle(.secondary)
        }
        Section {
            if engine.assetKeyStored {
                LabeledContent("fal.ai key") {
                    HStack {
                        Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Remove") { run { await engine.setFalKey(nil) } }
                    }
                }
            } else {
                HStack {
                    SecureField("fal.ai key", text: $key, prompt: Text("Paste a key from fal.ai"))
                    Button("Save") {
                        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        key = ""
                        run { await engine.setFalKey(k) }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Link("Get a key at fal.ai", destination: URL(string: "https://fal.ai/dashboard/keys")!)
            }
            if let failed { Text(failed).foregroundStyle(.red).textSelection(.enabled) }
        } header: {
            Text("3D models")
        } footer: {
            Text("3D models are made by fal.ai (Tripo P1, $0.50 each) with your key, within each game's \(engine.assetBudget.formatted(.currency(code: "USD"))) asset budget. The key is kept in your keychain. Without one, the builder models objects with simple shapes.")
                .foregroundStyle(.secondary)
        }
        .disabled(busy)
    }

    @ViewBuilder private var gaea: some View {
        let models = engine.gaeaModels
        if let models {
            Picker("Gaea's model", selection: setting(\.gaeaModel, "gaea_model")) {
                Text("Gaea's choice for this Mac").tag("")
                if !models.isEmpty { Divider() }
                ForEach(models) { m in
                    Text(m.licence.isEmpty ? m.title : "\(m.title) (\(m.licence))").tag(m.id)
                }
                // A model named in the settings that Gaea no longer offers.
                if !engine.gaeaModel.isEmpty, !models.contains(where: { $0.id == engine.gaeaModel }) {
                    Text("\(engine.gaeaModel) (not offered now)").tag(engine.gaeaModel)
                }
            }
            .accessibilityLabel("Gaea's model")
            Label(models.isEmpty ? "Gaea is running but offers no picture model. Add one with `gaea plugins add`." : "Gaea is running, with \(models.count) picture \(models.count == 1 ? "model" : "models").",
                systemImage: models.isEmpty ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Label(engine.gaeaChecked ? "Gaea isn't answering. Start Gaea.app; until then, builders use simple shapes for pictures." : "Asking Gaea…",
                    systemImage: engine.gaeaChecked ? "exclamationmark.triangle" : "hourglass")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check Again") { Task { await engine.refreshGaea() } }
            }
        }
        LabeledContent("Address", value: engine.gaeaURL.isEmpty ? Gaea.defaultBase : engine.gaeaURL)
            .help("assets.gaea_url in the engine's settings")
    }

    /// A picker binding that writes the engine setting `assets.<key>`.
    private func setting(_ path: ReferenceWritableKeyPath<EngineModel, String>, _ key: String) -> Binding<String> {
        Binding(get: { engine[keyPath: path] }, set: { value in
            guard value != engine[keyPath: path] else { return }
            engine[keyPath: path] = value
            run { await engine.setAssetSetting(key, value) }
        })
    }

    private func run(_ action: @escaping () async -> String?) {
        busy = true
        failed = nil
        Task {
            failed = await action()
            busy = false
        }
    }
}
