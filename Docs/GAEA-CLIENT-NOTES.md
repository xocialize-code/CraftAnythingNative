# Connecting a client to Gaea: notes from Craft Anything

Craft Anything is the first real client of Gaea, the MES media server on this Mac. It makes game pictures through
Gaea (`image.generate`). These notes record what it took and what we ran into, for the next app that connects
and for the Gaea area. Started 2026-11-08.

## How Craft Anything talks to Gaea

- **Who sends the jobs.** The engine (our fork's `crates/engines/src/assets/gaea.rs`), from Rust with `ureq`, not the
  app. The app only reads `GET /operations` to show Gaea's state and picture models in Settings
  (`Sources/CraftEngineKit/Gaea.swift`).
- **Where it connects.** Loopback, `http://127.0.0.1:17630/mes/v0`, with no auth: open mode, this Mac only.
  `[assets] gaea_url` moves it.
- **The job:**
  1. `POST /jobs` with `{"operation": "image.generate", "inputs": {"prompt"}, "params": {"size": {"width", "height"}},
     "client_ref": "craft-anything"}`, plus `"model"` when `[assets] gaea_model` names one. Otherwise Gaea chooses.
  2. `GET /jobs/{id}?wait=5` until `state` is `holding`. If the job is `purged` first, it failed; the job's `error`
     says why.
  3. Fetch `result.outputs[0].href`. It's a path on Gaea's own host (`/mes/v0/jobs/{id}/outputs/0`), so join it to the
     origin, not to the base URL.
  4. `POST /jobs/{id}/confirm`, so Gaea drops the output at once instead of after its TTL.
- **Credit.** `result.provenance.model` (`title`, `license.spdx`, `license.notice`) becomes the asset's `made_with`,
  and the builder copies it into the game's `CREDITS.md`. MES §10.2 rule 1 requires a client to show a `notice`.
- **Errors, as the builder hears them:**

  | What happened | What the builder is told |
  |---|---|
  | Nothing listening | "Gaea isn't answering … use simple shapes", and tell the person to start Gaea |
  | 404 `unknown_operation`, or 422 `model_unavailable` | No picture model; add one with `gaea plugins add` |
  | 429, or 503 `no_capacity` | Busy; try again |
  | Any other 400 or 422 | Refused, with Gaea's message |

## Decisions and why

- **No `MES-Version` header.** It's only a SHOULD (base §2.3), and an unsupported version is a hard 400
  `unsupported_version`. A client that sends nothing gets the engine's version; one that sends a stale one breaks.
  Revisit once there's a reason to pin.
- **Gaea chooses the model by default.** Its normalizer picks the default offer and a lane that fits the Mac's memory,
  so a 16 GB Mac and a 128 GB Mac both work without settings. The person can still name a model.
- **Polls of 5 s, and a 45-minute ceiling per picture.** The first job on a fresh model may load or download weights.
  The poll is short because `?wait` answers early only when the state changes (see finding 7).
- **Outputs are PNG by default** (Image profile §1.2), which is what a game needs, so the request names no `output`.

## Setting up Gaea on a Mac (operator steps)

Done on the Mac Studio (M5 Max, 128 GB, macOS 27.3), 2026-11-08.

1. **Install or update Gaea.app.**
   - This Mac had 0.15.0 (from 2026-11-03), not running; the current release was 1.2.0. 0.15.0 didn't update itself
     while it wasn't running, so the new release went in by hand: `gh release download v1.2.0 -R xocialize-code/gaea`.
   - Before installing, check the zip's sha256 against `.sha256` and `release.json`, then `codesign --verify --deep
     --strict` and `spctl -a` ("Notarized Developer ID", team CFZS6RXUCP).
   - The old app went to `~/Library/Application Support/Gaea/Updates/Gaea-0.15.0.app`, where Gaea's own updater
     keeps the previous version.
   - The 0.15.0 database and settings carried over: the models root, the trust list and the 103 GB budget.
2. **Start it.** `open -g -a /Applications/Gaea.app` puts it in the menu bar, and MES answers about 2 s later. Use
   `--headless` for a Mac nobody sits at.
3. **The CLI** isn't on the PATH: it's `/Applications/Gaea.app/Contents/Helpers/gaea`. `gaea status` is the first
   thing to run.
4. **Check the models root** (`gaea models root`).
   - The weights a plugin needs must be under that root, or the first job downloads them.
   - This Mac's root was `/Volumes/DEV_VOL1` (an external PCIe SSD), but the Z-Image snapshots were in
     `/Volumes/DEV_VOL1/Models` and in MLXEngine's store in `~/Library/…`, **not under the root**. So the first job
     downloaded a second 19 GB copy (finding 1). Since 2026-11-09 the root is `/Volumes/DEV_VOL1/Models`.
   - Since Gaea 1.3, `gaea plugins add` and `gaea models` name the weights that aren't under the root and would
     download.
5. **Add a picture model.**
   - `gaea plugins add https://github.com/xocialize-code/gaea-plugin-z-image` took a few seconds: a signed,
     notarized bundle, enabled at once.
   - `image.generate` then offers `z-image-turbo` (the default) and `z-image`, both Apache-2.0. Z-Image also adds
     named-only `image.edit`, `image.fill` and `image.extend` offers.
   - Lanes: int4 (default, 39.9 GB scheduled), int8 and bf16.
6. **Warm the model before anyone waits on it** (Gaea 1.3+): `gaea plugins warm <id> [model] [lane]` downloads any
   missing weights and loads the model. Without it, the first job does that while a builder waits.
7. **Check it from the client side.**
   - `Tools/gaea/picture-check.py` makes one picture through the pinned engine, the way a builder does.
   - In the app, Settings › Game assets should say "Gaea is running, with 2 picture models".

## Measured

M5 Max, 128 GB; Gaea 1.2.0; z-image plugin 0.1.2; int4 lane; weights on an external PCIe SSD; engine `9d2c359`.

| Picture | Wall time from the client | Gaea's `run_ms` |
|---|---|---|
| First job ever, right after `gaea plugins add`, 1024²: **507 s of it downloading 19 GB of weights** (finding 1) | 531.3 s | 531,303 |
| Second job (warm worker), 1024×576 | 9.6 s | 9,571 |
| After `gaea plugins disable` + `enable` (new worker process, the OS's caches warm), 1024² | 19.0 s | 18,948 |

- The output is a PNG at exactly the size asked for, RGBA, with no `size_snapped` warning.
- After the jobs, the worker stays resident and charged at 14.26 GB of the 103 GB budget.
- With the models root corrected, Gaea's own check on 2026-11-09 made a 512² Z-Image picture in 7 s with nothing
  downloaded (AB-R-0805).

## What we ran into

Each finding says what happened, what we did, and whether the Gaea area has it.

1. **The very first picture after installing the plugin took almost nine minutes; later cold starts take 19 s.**
   - We guessed at Metal compiling shaders or a first read off the SSD. **It was a download.** Gaea traced it: the
     models root pointed at the folder above the Z-Image snapshots, so the first job downloaded
     `mlx-community/Z-Image-Turbo-bf16` again, 19 GB into `/Volumes/DEV_VOL1/models--mlx-community--Z-Image-Turbo-bf16`,
     in 507 of the 531 s. The 19 s cold start is the real load cost.
   - Nothing told the client: `run_ms` included the download, `provenance.timings` had no `prepare_ms`, and the job
     reported no `preparing` stage. From a builder's side, a game's first asset hung for nine minutes. Our 45-minute
     ceiling held.
   - **What we did:** asked the Gaea area (AB-A-0259). Gaea fixed the root on this Mac, and Gaea 1.3 reports the
     wait: `progress.stage` `preparing`, with "downloading the weights (first use): x of y GB", then the load. `gaea
     plugins add` names missing weights, and `gaea plugins warm` loads a model ahead of time.
   - **Done (fork `2ab3a1b`):** the builder passes Gaea's `preparing` message on ("Making a picture with Gaea:
     downloading the weights (first use): 4.2 of 19.0 GB"). An older Gaea, which says nothing, still gets "loading
     the picture model (slow on its first use)".
   - **For the next client:** check the models root, and run `gaea plugins warm` after adding a plugin.
   - The spare 19 GB copy is still on `/Volumes/DEV_VOL1`; deleting it is the operator's call.
2. **Gaea reports progress well while a job runs.** The progress has `stage`, `message` (`denoise`), `step`, `steps`
   and `fraction`, then `finishing`. Our engine throws it away: an `AssetProvider` has no progress hook, so the
   builder sees nothing until the picture lands.
   - **Done (fork `1ae7c87`):** `AssetProvider::generate_reporting`. Gaea's provider says the job's progress once
     per change ("Making a picture with Gaea: denoise 5/8 (62%)"), and the asset tools pass it to `ctx.report`.
3. **The worker stays loaded after the job** (14.26 GB charged). That suits a builder making many assets in a row.
   Whether and when Gaea lets it go is the operator's policy, and something a client on a developer's Mac may want to
   know. **Answered:** a worker idle for 900 s is stopped; `gaea workers idle <seconds>` changes it (Gaea 1.3), and
   since 1.4 `GET /health` says so (`memory.idle_unload_s`, and `resident_until` per worker). We don't read it yet.
4. **Pictures came back RGBA when the model drew opaque** (RGB since Gaea 1.4). That's harmless for games. It's worth knowing for a
   client that compares bytes, and Gaea's AUTHORING.md already says outputs may be re-encoded.
5. **`GET /jobs` lists a client's own jobs, with plan, provenance and timings, after the job has been confirmed.**
   That's how the timings above were read back. `client_ref` makes our jobs easy to pick out; set it.
6. **Gaea answers `MES-Version: 0.1`** with no request header sent. That confirms the decision to send none for now.
7. **`?wait` answers when the job's state changes, not its progress** (MES §7.3, as written).
   - With `wait=30`, a 19 s run sat in `running` and the client saw only its end.
   - At `wait=5` (fork `0581029`), the builder hears "denoise 5/8 (62%)" at 5 s, then "finishing". On loopback the
     extra requests cost nothing.
   - A client that wants every step should use MES's event stream (§11) instead.
8. **Our engine's MCP server drops a progress message sent within 100 ms of the previous one.** That's upstream's
   design. The first "waiting its turn" lost out to "Making a picture…", which is harmless.

## Results on this Mac (2026-11-08)

- These came through the pinned engine and Gaea 1.2.0 with Z-Image Turbo int4, free and credited "Z-Image Turbo
  through Gaea (Apache-2.0)":
  - a mossy cobblestone texture (1024²)
  - a night sky (1024×576)
  - a treasure chest (1024²)
  - a knight (576×1024)
- All four are usable as game art, and the texture tiles.
- Settings › Game assets shows "Gaea is running, with 2 picture models". Naming Z-Image saves `assets.gaea_model`, and
  choosing "Gaea's choice" clears it.
- Bridge: receipt AB-R-0804, and ask AB-A-0259 to the Gaea area (findings 1 to 3 and the small ones), answered with
  Gaea 1.3 (AB-R-0805). The MES parts went on to mlx-apps as AB-A-0260 and shipped in Gaea 1.4.

## Gaea 1.3 to 1.5, and what we adopted (2026-11-09)

| Gaea change | Adopted? |
|---|---|
| `preparing` progress with Gaea's message (1.3) | Yes, fork `2ab3a1b`: the builder says Gaea's words |
| `gaea plugins warm`, and `plugins add` naming missing weights (1.3) | Yes, in setup step 6 |
| `gaea workers idle <seconds>` (1.3) | Nothing for a client to do |
| `provenance.timings.prepare_ms` (1.4) | Not read. It would only matter for our own measurements |
| `GET /health` `memory.idle_unload_s` and `resident_until` (1.4) | Not read. Settings could say "unloads after 15 min idle" |
| RGB PNGs for opaque pictures (1.4) | Nothing to do: games take either |
| `mesh.generate`, 3D models through the TRELLIS.2 plugin (1.4) | Not yet. It's plan item B2, 3D from Gaea with fal.ai's Tripo kept for Macs too small for TRELLIS.2 (its lightest model needs about 38 GB) |
| Operator caps on models, lanes and memory (1.5) | Nothing to do: we already say Gaea's refusals plainly |

