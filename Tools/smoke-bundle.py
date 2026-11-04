"""Checks a built CraftAnythingNative.app the way it runs for people, before it's released.

    python3 Tools/smoke-bundle.py <CraftAnythingNative.app> <output folder>

In a fresh settings folder, the bundled engine (`Contents/MacOS/craft-anything-cli mcp`) loads the
bundled WebKit plugin from its own `--print-config` entry, lists it with no problem, and serves the
website browser set through it: open a page served on loopback, capture it at one width, close it.
That runs every program in the bundle except the app window (Tools/release.sh checks that one) under
its release signature, hardened runtime included. Exits non-zero, saying why, on the first failure.
"""
import http.server, json, os, pathlib, subprocess, sys, tempfile, threading

app = pathlib.Path(sys.argv[1]).resolve()
out = pathlib.Path(sys.argv[2]).resolve()
macos = app / "Contents/MacOS"


def fail(why):
    print(f"smoke: {why}", file=sys.stderr)
    sys.exit(1)


settings = pathlib.Path(tempfile.mkdtemp(prefix="cany-smoke-"))
entry = subprocess.run([str(macos / "craft-anything-native-tools"), "--print-config"], capture_output=True, text=True, check=True).stdout
if str(macos / "craft-anything-native-tools") not in entry:
    fail(f"the plugin's --print-config doesn't name the bundled plugin:\n{entry}")
(settings / "config.toml").write_text("ask_before_running = false\n\n" + entry)

page = b"<!doctype html><html lang=en><head><meta name=viewport content='width=device-width'><title>Smoke</title></head><body style='font:16px sans-serif;margin:40px'><h1>Release smoke test</h1><p style='height:1200px'>Tall.</p></body></html>"


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        self.wfile.write(page)

    def log_message(self, *a):
        pass


site = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=site.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{site.server_address[1]}/"

env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE" and not k.startswith("CLAUDE_CODE_")}
env["CRAFT_ANYTHING_CONFIG_DIR"] = str(settings)
err = open(out / "smoke-engine.log", "w")
engine = subprocess.Popen([str(macos / "craft-anything-cli"), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, text=True, bufsize=1, env=env)
n = 0


def request(method, params):
    global n
    n += 1
    engine.stdin.write(json.dumps({"jsonrpc": "2.0", "id": n, "method": method, "params": params}) + "\n")
    engine.stdin.flush()
    while True:
        line = engine.stdout.readline()
        if not line:
            fail(f"the engine stopped during {method} (smoke-engine.log)")
        m = json.loads(line)
        if m.get("id") == n:
            return m


def call(name, args):
    r = request("tools/call", {"name": name, "arguments": args}).get("result", {})
    if r.get("isError"):
        fail(f"{name} failed: {json.dumps(r)[:1500]}")
    return (r.get("structuredContent") or {}).get("result")


try:
    request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "release-smoke", "version": "1"}})
    plugins = call("plugins_list", {}) or {}
    mac_app = next((p for p in plugins.get("plugins", []) if p.get("id") == "mac_app"), None)
    if not mac_app or not mac_app.get("enabled") or mac_app.get("problem"):
        fail(f"the engine doesn't load the bundled plugin cleanly: {json.dumps(plugins)[:1500]}")
    opened = call("web_site_open", {"url": url, "settle_ms": 300}) or {}
    if opened.get("title") != "Smoke":
        fail(f"web_site_open: {json.dumps(opened)[:1500]}")
    shots = out / "smoke-capture"
    reply = request("tools/call", {"name": "web_site_capture", "arguments": {"output_directory": str(shots), "widths": [800]}}).get("result", {})
    if reply.get("isError") or not (shots / "screenshot-800.png").is_file():
        fail(f"web_site_capture wrote no screenshot-800.png in {shots}: {json.dumps(reply)[:1500]}")
    if "Pictured with WebKit" not in json.dumps(reply):
        fail("web_site_capture's reply has no WebKit note: the engine's own browser answered, not the plugin")
    if (call("web_site_close", {}) or {}).get("closed") is not True:
        fail("web_site_close didn't close the page")
    print(f"smoke: ok: the bundled engine loaded plugin mac_app; WebKit opened, captured and closed {url}")
finally:
    engine.stdin.close()
    try:
        engine.wait(timeout=60)
    except subprocess.TimeoutExpired:
        engine.kill()
    site.shutdown()
