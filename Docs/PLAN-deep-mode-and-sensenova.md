# Deep mode, and game assets through Gaea: plan

2026-11-08. Shell at `bc1b315` (0.2.0), engine pin `46df5b9` (our fork's `native`, upstream 0.4.0).

## Where things stand

**Deep mode in the native app today.** The app starts the engine with `--all-tools` and reads `clean_room` once, from
`core_session_show`. The toolbar and Tools screen say "Clean room" or "Deep mode", but nothing can change it. There is
no Ghidra status, no way to look inside an original, and no evidence views. The WebKit plugin already does the right
thing outside Clean room: it reads `_meta.clean_room` on each call and keeps `page.html`, load errors and failed
requests when it's off.

**Deep mode in the engine.** Deep mode is one saved setting, `deep_mode`, set with `settings_set deep_mode true`. Every
engine process reads it, so builders follow it too. In Clean room, `engine/src/clean_room.rs` refuses every tool off
its allow-list, with `details.reason = "clean_room"`. With Deep on and Ghidra installed, `native_function_pseudocode`
uses Ghidra under the same tool id. The Rust app shows Deep mode in these places:

- a title-bar switch and a Settings switch (turning it on offers to get Ghidra)
- New Build's "How closely may Craft Anything look at it?" tiles, with a Ghidra memory line for programs
- "Look inside" (an app or file, or a website): a chat with an agent that has the engine's tools
  - That chat runs **in process** (`AiHub`), not through an MCP tool, so the native app can't call it as it is.
- the Game files viewer
- the Advanced workbench: functions, strings, pseudo-C, disassembly, hex, call graphs, evidence, unknowns, jobs, log
  and the agent console. Its list views are generic: `workbench.rs` finds the list in any tool result.

**Deep website tools need Chromium.** Our WebKit plugin doesn't replace `web_page_watch`, `web_page_js_analyze`,
`web_modules_trace`, `web_scripts_save`, `web_coverage_measure`, `web_listeners_list` or `web_walkthrough_record`. They
speak CDP and launch a Chromium they find on their own.

**Fal in the engine.** Fal makes the generated game assets:
- **The code.** `engines/src/assets/` holds an `AssetProvider` trait and a registry, with one built-in provider,
  `fal`.
- **The models.** `assets.toml` lists three picture models: Nano Banana Pro (the default, $0.15 a picture), FLUX dev
  and FLUX schnell. It lists one image-to-3D model, Tripo P1 ($0.40, or $0.50 textured).
- **The tools.** `assets_image_generate` and `assets_model_generate` check the project's `generate_assets` switch and
  its budget, ask over the inbox when the budget is used up, and record each file and its cost in the project.
- **Keys.** Both tools refuse unless some provider has a key.
- **Fal is named in the text.** The tool summaries, the builder's brief (`rebuild/brief.rs`) and the required
  `CREDITS.md` line all say "fal.ai".
- **The native app can't turn it on.** New Build never sends `generate_assets`, so a native build can't generate
  assets today.

**SenseNova.** `mlxengine-image/PROD/sensenova-u1-swift` is at v0.6.0.
- **Licence.** The port is MIT and the weights are Apache-2.0 (AB-D-0043).
- **What it does.** Text-to-image, instruction edits and VQA, with one model resident. It's an MLXEngine package
  (`MLXSenseNovaU1`), and it needs **macOS 26** and swift-tools 6.2.
- **The fast tiers.** 8step-v2-4bit holds 12.2 GB resident and peaks 4.5 GB higher; a 1024² picture takes about 3.2 s
  on an M5 Max. 8step-v2-8bit holds 20.5 GB.
- **16 GB Macs** have only the ≤768² fill window (AB-D-0141).
- **Prior art.** `gaea-plugin-sensenova` is the integration to copy, and its `sensenova-inproc` runs the model in
  process through MLXServeEngine.
- **No 3D.** SenseNova makes pictures, not 3D models. Nothing in it replaces Tripo. `mlx-trellis2-swift` (TRELLIS.2)
  does image-to-3D, but it has only been checked from the command line, not inside an app (🟡 in
  `mlxengine-3d/APP-VALIDATION.md`).

## Part A: Deep mode

A1–A3 need no engine changes.

**A1. The switch.**
- Put a Clean room / Deep control in the toolbar and in Settings. It calls `settings_set deep_mode`, then reads
  `core_session_show` again, along with the tool list if the engine announces `tools/list_changed`.
- Turning Deep on shows a short confirmation: "for your private use", and what Deep reads.
- Show Ghidra's status from `settings_show` (`deep_mode.ghidra`), and offer to get it through `engines_install`. That
  consent comes over the inbox, which we already handle.

**A2. New Build.**
- Add the "How closely may it look?" choice (Clean room or Deep), the same setting as the switch.
- For an app or file original, add the Ghidra line.
- The engine keeps no record of the mode a project was studied in, so projects can't show it yet. That would
  need a fork patch, like the browser record.
- Add the **Generated assets** switch and budget (`generate_assets` on `rebuild_start`). Part B needs this too.

**A3. Refusals that offer Deep.** When a result is a Clean room refusal (`details.reason == "clean_room"`), the Tools
form and the project screen show a "Turn on Deep mode" button instead of a bare error.

**A4. Look inside.** This is the debugging tool.
- **Inspector.** Pick an app or file. The inspector opens it with `core_target_open` and `core_target_triage`, and
  shows:
  - an overview
  - generic list tables, like `workbench.rs`'s `rows()`, for functions, strings and imports
  - pseudo-C (Ghidra when it's there) and hex
  - evidence (`core_evidence_browse` / `core_evidence_show`) and unknowns (`core_unknowns_show`)

  It's plain tool calls, built on what the Tools screen already does.
- **Ask.** A conversation about the open target. Swift runs the person's own `claude -p --output-format stream-json`.
  The engine is its MCP server and `core_action_approve` is its permission prompt, as upstream's `CliSpec` does.
  - Driving Claude Code natively is already on the README's stage-2 list.
  - The alternative is a fork patch that serves the `AiHub` chat as an MCP tool. That adds fork churn and streams
    badly over MCP.
- **Websites.** Deep captures already keep the page's HTML, errors and requests with WebKit. The CDP tools above use
  Chromium. The app checks for a Chromium (`web_browser_connect`) and says when one is missing, rather than failing
  later.

**Checks.**
- Engine-backed tests: switching to Deep stops a tool off the allow-list from being refused, and switching back
  refuses it again. The existing WebKit test already covers `clean_room: false`.
- An AppProbe hand-test checklist for the switch, New Build and the inspector.

## Part B: game assets through Gaea, in place of Fal

**Decided 2026-11-08:** use Gaea rather than embedding SenseNova. Craft Anything can then use any image model Gaea
offers, and Gaea picks a model that fits the Mac's memory, including on 16 GB. The macOS 26 floor is approved for
whatever needs it.

The engine keeps owning the project: the budget, the per-project switch, the asset records, the brief and the inbox
question. Gaea is one more `AssetProvider`, and it needs no key.

**Rejected: a native tool that takes over `assets_image_generate`.** Swift would then have to write the project's
asset records and run the budget question itself, before stage 2 ports project files byte for byte.

**B1. Fork patch.** One commit on `native`, in `engines/src/assets/`, which stands on its own.
- `AssetProvider::needs_key()`, true by default. The tools stop refusing when the chosen model's provider needs none.
- A `gaea` provider. It speaks MES over loopback HTTP, the way `fal.rs` speaks to fal:
  - `POST /mes/v0/jobs` with `image.generate`, then `GET /mes/v0/jobs/<id>?wait=10` until it's done, then fetch
    `result.outputs[].href`.
  - The default address is `http://127.0.0.1:17630`. A setting changes it.
  - Each picture costs $0, and the model and seed Gaea used (`result.effective`) go in the asset record.
- An `assets.toml` entry with `id = "gaea"`, `provider = "gaea"`, and an empty model name, so Gaea picks its default
  for this Mac. A setting `assets.gaea_model` names another of Gaea's models instead.
- The tool summaries, `brief.rs` and the `CREDITS.md` line name the provider and the model actually used, not
  "fal.ai".
- `assets_model_generate` from a prompt sends its picture to Tripo as a `data:` URI when the provider has no web
  address.

**B2. 3D models.** Gaea has no 3D operation in MES yet. The spec's operations are image, audio and video.
- Until it has one, 3D models stay on Fal's Tripo, used only when a fal.ai key is set up. Their pictures still come
  from Gaea, which saves $0.15 a model.
- When Gaea offers image-to-3D (the fleet has a TRELLIS.2 port, `mlx-trellis2-swift`), the 3D path moves to Gaea
  the same way.
- Decide when Gaea gets 3D whether to drop Fal entirely.

**B3. App.** Settings → Game assets gets these controls:
- whether Gaea is running at the address, with the image models it offers (`GET /mes/v0/operations`) and the one in
  use
- "Pictures: Gaea / fal.ai"
- the fal.ai key, for 3D models

When Gaea isn't running, the app says so and links to it. The engine's own error says to use simple shapes.

**Quality.** Before Gaea becomes the default for pictures, run a small blind bake-off: about ten asset prompts of the
kinds the brief asks for (textures, skies, props on plain backgrounds, title art), Gaea's default against Nano Banana
Pro. No receipt for this exists yet.

## Order

There's no rush, so this can run in any order.

1. **A1–A3:** the switch, New Build, Ghidra status, refusals that offer Deep, and the assets switch. In progress.
2. **B1 and B3:** prove one game build end to end with pictures from Gaea, then move the engine pin.
3. **A4:** the inspector first, then Ask (Claude Code driven from Swift).
4. **Release 0.3.0**, with notes. The fork carries one more commit, recorded in the README's pin section.

## Decisions

1. Deep mode: build every part, in any order.
2. Game assets: through Gaea, not SenseNova inside the app.
3. 16 GB Macs: Gaea's tiering picks the model.
4. A macOS 26 floor is approved.
