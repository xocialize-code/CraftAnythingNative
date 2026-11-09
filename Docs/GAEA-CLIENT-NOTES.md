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
4. **Check the models root.**
   - This Mac's was `/Volumes/DEV_VOL1` (an external PCIe SSD), not MLXEngine's store in `~/Library/…`. The operator
     had moved it on 2026-11-03.
   - The weights a plugin needs must be under that root, or the first job downloads them. Z-Image's bf16 snapshots
     were already on both.
5. **Add a picture model.**
   - `gaea plugins add https://github.com/xocialize-code/gaea-plugin-z-image` took a few seconds: a signed,
     notarized bundle, enabled at once.
   - `image.generate` then offers `z-image-turbo` (the default) and `z-image`, both Apache-2.0. Z-Image also adds
     named-only `image.edit`, `image.fill` and `image.extend` offers.
   - Lanes: int4 (default, 39.9 GB scheduled), int8 and bf16.
6. **Check it from the client side.**
   - `Tools/gaea/picture-check.py` makes one picture through the pinned engine, the way a builder does.
   - In the app, Settings › Game assets should say "Gaea is running, with 2 picture models".

## Measured

M5 Max, 128 GB; Gaea 1.2.0; z-image plugin 0.1.2; int4 lane; weights on an external PCIe SSD; engine `9d2c359`.

| Picture | Wall time from the client | Gaea's `run_ms` |
|---|---|---|
| First job ever, right after `gaea plugins add` (new bundle, cold worker), 1024² | 531.3 s | 531,303 |
| Second job (warm worker), 1024×576 | 9.6 s | 9,571 |
| After `gaea plugins disable` + `enable` (new worker process, the OS's caches warm), 1024² | 19.0 s | 18,948 |

- The output is a PNG at exactly the size asked for, RGBA, with no `size_snapped` warning.
- After the jobs, the worker stays resident and charged at 14.26 GB of the 103 GB budget.

## What we ran into

Each finding says what happened, what we did, and whether the Gaea area has it.

1. **The very first picture after installing the plugin took almost nine minutes; later cold starts take 19 s.**
   - A new worker process, with the OS's caches warm, loaded and drew in 19 s, so the 531 s is a one-time cost of a
     newly installed bundle.
   - The likely causes are Metal compiling the bundle's shaders on their first use, or the first read of about 19 GB
     of weights off the SSD. We didn't separate the two, and neither did Gaea: `run_ms` includes the load,
     `provenance.timings` has no `prepare_ms`, and there was no warning.
   - From a builder's side, a game's first asset hangs for nine minutes. Our 45-minute ceiling held.
   - **What we did:** asked the Gaea area whether `plugins add` could warm a new plugin, and whether `prepare_ms` (or
     a `preparing` progress stage) can show the load.
   - **For the next client:** make one throwaway job after setting up Gaea, before a person waits on one.
2. **Gaea reports progress well while a job runs.** The progress has `stage`, `message` (`denoise`), `step`, `steps`
   and `fraction`, then `finishing`. Our engine throws it away: an `AssetProvider` has no progress hook, so the
   builder sees nothing until the picture lands.
   - **Done (fork `1ae7c87`):** `AssetProvider::generate_reporting`. Gaea's provider says the job's progress once
     per change ("Making a picture with Gaea: denoise 5/8 (62%)"), and the asset tools pass it to `ctx.report`.
3. **The worker stays loaded after the job** (14.26 GB charged). That suits a builder making many assets in a row.
   Whether and when Gaea lets it go is the operator's policy, and something a client on a developer's Mac may want to
   know.
4. **Pictures come back RGBA when the model draws opaque.** That's harmless for games. It's worth knowing for a
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
- Bridge: receipt AB-R-0804, and ask AB-A-0259 to the Gaea area (findings 1 to 3 and the small ones).
