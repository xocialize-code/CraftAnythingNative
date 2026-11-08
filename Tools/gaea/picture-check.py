#!/usr/bin/env python3
"""Make one game picture through the pinned engine and a running Gaea, the way a builder does.

    Tools/gaea/picture-check.py [--gaea http://127.0.0.1:17630/mes/v0] [--model <gaea model id>]
                                [--prompt "..."] [--shape square|wide|tall] [--out picture.png]

It sets up a throwaway game project (generated assets on) and engine settings in a temp folder,
starts Engine/bin/craft-anything-cli as `mcp --inbox <game>/inbox`, points `assets.gaea_url` at
Gaea and calls assets_image_generate. It prints what the engine answered (saved, made_with, cost)
and the time it took, and copies the picture to --out. The person's own settings and projects
aren't touched. Gaea must be running with a picture model (`gaea models`).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "Engine" / "bin" / "craft-anything-cli"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--gaea", default="http://127.0.0.1:17630/mes/v0")
    ap.add_argument("--model", default="")
    ap.add_argument("--prompt", default="A mossy cobblestone texture for a fantasy game, seamless, top-down, soft daylight")
    ap.add_argument("--shape", default="square", choices=["square", "wide", "tall"])
    ap.add_argument("--out", default="gaea-picture.png")
    a = ap.parse_args()
    if not ENGINE.exists():
        sys.exit(f"No engine at {ENGINE}: run Tools/engine/pin-engine.sh")

    with tempfile.TemporaryDirectory(prefix="gaea-check-") as tmp:
        tmp = Path(tmp)
        game, config = tmp / "game", tmp / "config"
        (game / "inbox").mkdir(parents=True)
        config.mkdir()
        manifest = {"version": 2, "name": "Gaea check", "request": "A small fantasy game", "target": {"kind": "none"},
                    "created_ms": 0, "updated_ms": 0, "stack": "Godot", "generate_assets": True}
        (game / "craft.json").write_text(json.dumps(manifest))
        env = dict(os.environ, CRAFT_ANYTHING_CONFIG_DIR=str(config))
        env.pop("FAL_KEY", None)
        p = subprocess.Popen([str(ENGINE), "mcp", "--inbox", str(game / "inbox")], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, text=True)
        n = 0

        def rpc(method, params=None):
            nonlocal n
            n += 1
            p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": n, "method": method, "params": params or {}}) + "\n")
            p.stdin.flush()
            while True:
                line = p.stdout.readline()
                if not line:
                    sys.exit("The engine stopped.")
                m = json.loads(line)
                if m.get("id") == n:
                    return m

        def call(name, args):
            r = rpc("tools/call", {"name": name, "arguments": args})["result"]
            return r.get("isError", False), json.loads(r["content"][0]["text"])

        try:
            rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "gaea-check", "version": "0"}})
            call("settings_set", {"key": "assets.gaea_url", "value": a.gaea})
            if a.model:
                call("settings_set", {"key": "assets.gaea_model", "value": a.model})
            started = time.monotonic()
            failed, out = call("assets_image_generate", {"prompt": a.prompt, "save_as": "assets/generated/check.png", "shape": a.shape})
            took = time.monotonic() - started
            print(json.dumps(out, indent=2))
            print(f"took {took:.1f} s")
            if failed:
                return 1
            shutil.copy(game / "app" / "assets" / "generated" / "check.png", a.out)
            print(f"picture: {Path(a.out).resolve()}")
            return 0
        finally:
            p.stdin.close()
            p.wait(timeout=20)


if __name__ == "__main__":
    sys.exit(main())
