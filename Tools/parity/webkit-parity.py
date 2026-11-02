#!/usr/bin/env python3
"""Capture the same pages through the pinned engine twice, once with its own Chromium and once with
the WebKit browser set (craft-anything-native-tools as a plugin that `replaces` it), then compare
what the two wrote: the file sets, picture sizes, page facts and counts, and the score the rebuild's
website check gives (web_pixels_compare: layout and detail, (layout + detail) * 50) between the two
renderers and between two runs of the same one.

  Tools/parity/webkit-parity.py OUT_DIR [URL ...]

With no URLs it uses a few public pages and a local page with a menu, a dialog, tabs and a
collapsed section. Each run gets its own settings folder (CRAFT_ANYTHING_CONFIG_DIR), in Deep mode
with approvals off, so nothing of the person's own settings is read or changed. Writes OUT_DIR/report.md.
"""
import http.server
import json
import os
import pathlib
import struct
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
ENGINE = ROOT / "Engine/bin/craft-anything-cli"
WIDTHS = [1440, 390]

FIXTURE = """<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Fixture</title>
<style>body{font:16px/1.5 -apple-system,Helvetica,Arial,sans-serif;margin:0}header{display:flex;gap:24px;padding:16px 32px;background:#0b3d91;color:#fff}
main{max-width:960px;margin:0 auto;padding:48px 32px}.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:24px}.card{padding:24px;border-radius:12px;background:#f1f4f9}
@media (max-width:700px){.cards{grid-template-columns:1fr}}[role=menu]{display:none;position:absolute;background:#fff;color:#000;padding:8px;box-shadow:0 4px 12px #0003}
[aria-expanded=true]+[role=menu]{display:block}dialog{border-radius:12px}</style></head><body>
<header><strong>Fixture</strong><div style="position:relative"><button aria-expanded="false" aria-haspopup="menu" onclick="this.setAttribute('aria-expanded', this.getAttribute('aria-expanded')==='true'?'false':'true')">Products</button>
<div role="menu"><a href="#a">Alpha</a><br><a href="#b">Beta</a></div></div>
<button aria-haspopup="dialog" onclick="document.querySelector('dialog').showModal()">Sign up</button></header>
<dialog onkeydown="if(event.key==='Escape')this.close()"><p>Join us</p><button onclick="this.closest('dialog').close()">Close</button></dialog>
<main><h1>A page with parts that open</h1><p>Menus, a dialog, tabs and a collapsed section, for comparing browsers.</p>
<div role="tablist"><button role="tab" aria-selected="true">One</button><button role="tab" aria-selected="false" onclick="this.setAttribute('aria-selected','true')">Two</button></div>
<details><summary>More</summary><p>Hidden until opened.</p></details>
<section class="cards"><div class="card"><h2>First</h2><p>One</p></div><div class="card"><h2>Second</h2><p>Two</p></div><div class="card"><h2>Third</h2><p>Three</p></div></section>
</main></body></html>"""

PAGES = ["https://example.com/", "https://developer.apple.com/swift/", "https://en.wikipedia.org/wiki/WebKit"]


def serve_fixture():
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = FIXTURE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{s.server_address[1]}/"


class Engine:
    """craft-anything-cli mcp in its own settings folder."""

    def __init__(self, config_dir, plugin_toml=""):
        config_dir.mkdir(parents=True, exist_ok=True)
        (config_dir / "config.toml").write_text("deep_mode = true\nask_before_running = false\n\n" + plugin_toml)
        env = dict(os.environ, CRAFT_ANYTHING_CONFIG_DIR=str(config_dir))
        env = {k: v for k, v in env.items() if k != "CLAUDECODE" and not k.startswith("CLAUDE_CODE_")}
        self.p = subprocess.Popen([str(ENGINE), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1, env=env)
        self.n = 0
        self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "webkit-parity", "version": "1"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")

    def request(self, method, params):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n")
        self.p.stdin.flush()
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("the engine stopped")
            m = json.loads(line)
            if m.get("id") == self.n:
                return m

    def call(self, tool, args):
        t = time.time()
        r = self.request("tools/call", {"name": tool, "arguments": args}).get("result", {})
        sc = r.get("structuredContent") or {}
        if r.get("isError"):
            text = "".join(c.get("text", "") for c in r.get("content", []))
            return {"error": sc.get("message") or text[:300], "seconds": time.time() - t}
        return {"result": sc.get("result", sc), "evidence": sc, "seconds": time.time() - t}

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=30)


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return struct.unpack(">II", head[16:24]) if head[:8] == b"\x89PNG\r\n\x1a\n" else None


def capture_all(engine, out, urls):
    rows = []
    for i, url in enumerate(urls):
        page = out / f"page-{i}"
        page.mkdir(parents=True, exist_ok=True)
        row = {"url": url}
        row["open"] = engine.call("web_site_open", {"url": url})
        if "error" not in row["open"]:
            row["capture"] = engine.call("web_site_capture", {"output_directory": str(page / "capture"), "widths": WIDTHS, "noise_pass": True})
            row["states"] = engine.call("web_page_states_capture", {"output_directory": str(page / "states")})
        rows.append(row)
    engine.call("web_site_close", {})
    return rows


def score(engine, a, b, noise=None):
    if not (a.is_file() and b.is_file()):
        return None
    params = {"before": {"path": str(a)}, "after": {"path": str(b)}, "common_area": True, "tolerance": 24}
    if noise and noise.is_file():
        params["ignore"] = {"path": str(noise)}
    r = engine.call("web_pixels_compare", params)
    res = r.get("result") or {}
    layout, detail = res.get("layout_similarity"), res.get("perceptual_similarity")
    if layout is None:
        return None
    detail = layout if detail is None else detail
    return {"score": round((layout + detail) * 50, 1), "layout": round(layout * 100, 1), "detail": round(detail * 100, 1)}


def files(folder):
    return sorted(p.name for p in folder.iterdir()) if folder.is_dir() else []


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    out = pathlib.Path(sys.argv[1]).resolve()
    if out.exists():
        print(f"{out} already exists; give a new folder.")
        return 2
    urls = sys.argv[2:] or [serve_fixture()] + PAGES
    native = subprocess.run([str(ROOT / ".build/debug/craft-anything-native-tools"), "--print-config"], capture_output=True, text=True, check=True).stdout
    runs = {}
    for name, plugin in [("chromium", ""), ("chromium-again", ""), ("webkit", native), ("webkit-again", native)]:
        print(f"{name}…", flush=True)
        e = Engine(out / "settings" / name, plugin)
        runs[name] = capture_all(e, out / name, urls)
        e.close()

    judge = Engine(out / "settings" / "judge")
    md = [f"# WebKit browser set: parity with Chromium\n", f"Engine: `{(ROOT / 'Engine/bin/pin.txt').read_text().split()[0]}`. Widths {WIDTHS}. "
          "Score is the website check's: (layout + detail) × 50, comparing two pictures of the same page.\n"]
    for i, url in enumerate(urls):
        md.append(f"\n## {url}\n")
        c, w = runs["chromium"][i], runs["webkit"][i]
        for name in ["chromium", "webkit"]:
            r = runs[name][i]
            bad = [f"{k}: {r[k]['error']}" for k in ("open", "capture", "states") if k in r and "error" in r[k]]
            if bad:
                md.append(f"- **{name} failed**: {'; '.join(bad)}\n")
        if "capture" not in c or "capture" not in w or "error" in c["capture"] or "error" in w["capture"]:
            continue
        cf, wf = c["open"]["result"].get("facts", {}), w["open"]["result"].get("facts", {})
        md.append("\n| | Chromium | WebKit |\n|---|---|---|\n")
        for k in ["title", "width", "height", "elements", "images", "links"]:
            md.append(f"| page {k} | {cf.get(k)} | {wf.get(k)} |\n")
        cc, wc = c["capture"]["result"].get("counts", {}), w["capture"]["result"].get("counts", {})
        for k in ["outline", "headings", "links", "images", "forms"]:
            md.append(f"| {k} | {cc.get(k)} | {wc.get(k)} |\n")
        ch, wh = c["open"]["result"].get("health") or {}, w["open"]["result"].get("health") or {}
        md.append(f"| load errors / failed requests | {len(ch.get('errors', []))} / {len(ch.get('failed_requests', []))} | {len(wh.get('errors', []))} / {len(wh.get('failed_requests', []))} |\n")
        for k in ["capture", "states"]:
            md.append(f"| {k} seconds | {c[k]['seconds']:.1f} | {w[k]['seconds']:.1f} |\n")
        cdir, wdir = out / "chromium" / f"page-{i}", out / "webkit" / f"page-{i}"
        md.append(f"| capture files | {', '.join(files(cdir / 'capture'))} | {', '.join(files(wdir / 'capture'))} |\n")
        md.append(f"| states files | {', '.join(files(cdir / 'states'))} | {', '.join(files(wdir / 'states'))} |\n")
        for width in WIDTHS:
            shot = f"capture/screenshot-{width}.png"
            sizes = [png_size(out / run / f"page-{i}" / shot) if (out / run / f"page-{i}" / shot).is_file() else None for run in ("chromium", "webkit")]
            md.append(f"| {width} px picture | {sizes[0]} | {sizes[1]} |\n")
        md.append("\n| Check score at width | Chromium vs Chromium | WebKit vs WebKit | Chromium vs WebKit |\n|---|---|---|---|\n")
        for width in WIDTHS:
            shot = f"capture/screenshot-{width}.png"
            noise = lambda run: out / run / f"page-{i}" / f"capture/noise-{width}.png"
            pair = lambda a, b: score(judge, out / a / f"page-{i}" / shot, out / b / f"page-{i}" / shot, noise(a))
            fmt = lambda s: "—" if s is None else f"{s['score']} (layout {s['layout']}, detail {s['detail']})"
            md.append(f"| {width} | {fmt(pair('chromium', 'chromium-again'))} | {fmt(pair('webkit', 'webkit-again'))} | {fmt(pair('chromium', 'webkit'))} |\n")
        cs, ws = c["states"].get("result", {}), w["states"].get("result", {})
        label = lambda s: [f"{x.get('label')}: {', '.join(x.get('changed', [])) or 'nothing'}" for x in s.get("states", [])]
        md.append(f"\nStates found: Chromium {cs.get('found')}, WebKit {ws.get('found')}.\n\n- Chromium: {label(cs)}\n- WebKit: {label(ws)}\n")
    judge.close()
    (out / "report.md").write_text("".join(md))
    (out / "runs.json").write_text(json.dumps(runs, indent=2, default=str))
    print(out / "report.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
