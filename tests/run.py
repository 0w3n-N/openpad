#!/usr/bin/env python3
"""OpenPad test suite: security, sync, guests, live sessions and annotation.

Runs a real server on a free port with throwaway data directories; touches
nothing in your home folder. The desktop annotation tests use GStreamer's test
pattern instead of a real window (skipped without GStreamer). The notebook
merge rules are checked against web/model.js when Node is installed.

    python3 -B tests/run.py
"""

import base64
import copy
import datetime
import hashlib
import json
import plistlib
import random
import re
import ssl
import subprocess
import os
import shutil
import socket
import stat
import struct
import sys
import tempfile
import threading
import time
import zipfile

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = tempfile.mkdtemp(prefix="openpad-test-")
os.environ["XDG_DATA_HOME"] = os.path.join(TMP, "data")
os.environ["XDG_RUNTIME_DIR"] = os.path.join(TMP, "run")
os.environ["OPENPAD_NOTES"] = os.path.join(TMP, "notes")
os.makedirs(os.environ["XDG_RUNTIME_DIR"], mode=0o700)
sys.path.insert(0, ROOT)

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail and not cond else ""))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def tiny_pdf(pages=2):
    objs = ["<</Type/Catalog/Pages 2 0 R>>",
            f"<</Type/Pages/Kids[{' '.join(f'{3 + i} 0 R' for i in range(pages))}]/Count {pages}>>"]
    objs += ["<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>"] * pages
    out, offsets = "%PDF-1.4\n", []
    for i, o in enumerate(objs, 1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n{o}\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n" + "".join(f"{o:010d} 00000 n \n" for o in offsets)
    out += f"trailer\n<</Size {len(objs) + 1}/Root 1 0 R>>\nstartxref\n{xref}\n%%EOF\n"
    return out.encode()


# --------------------------------------------------------------------------- fake window source

try:
    import gi
    gi.require_version("Gst", "1.0")
    from gi.repository import Gst
    Gst.init(None)
    HAVE_GST = True
except (ImportError, ValueError):
    HAVE_GST = False


def jpeg_frames(w, h, n):
    p = Gst.parse_launch(f"videotestsrc num-buffers={n} pattern=smpte ! video/x-raw,width={w},height={h} "
                         "! jpegenc ! appsink name=s sync=false")
    sink = p.get_by_name("s")
    p.set_state(Gst.State.PLAYING)
    out = []
    while (smp := sink.emit("pull-sample")) is not None:
        b = smp.get_buffer()
        ok, m = b.map(Gst.MapFlags.READ)
        out.append(bytes(m.data))
        b.unmap(m)
    p.set_state(Gst.State.NULL)
    return out


class FakeCapture:
    """Stands in for WindowCapture: 'picks' a 640x400 window, then resizes it to 800x400."""

    def __init__(self, on_start, on_frame, on_resize, on_end, **_):
        self.cb = (on_start, on_frame, on_resize, on_end)
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.stopped.set()

    def _run(self):
        on_start, on_frame, on_resize, on_end = self.cb
        time.sleep(0.3)
        on_start(640, 400)
        for f in jpeg_frames(640, 400, 10):
            on_frame(f)
            time.sleep(0.05)
        on_resize(800, 400)
        for f in jpeg_frames(800, 400, 5):
            on_frame(f)
            time.sleep(0.05)
        self.stopped.wait(5)
        on_end("stopped")


from pathlib import Path  # noqa: E402

import openpad.capture as capture  # noqa: E402

capture.WindowCapture = FakeCapture
capture.missing_dependencies = lambda: [] if HAVE_GST else ["gstreamer"]

from openpad import notebook as N  # noqa: E402
from openpad.server import APP_ORIGIN, Hub, OpenPadServer, write_private  # noqa: E402
from openpad.store import Store  # noqa: E402

PORT = free_port()
srv = OpenPadServer("127.0.0.1", PORT)
threading.Thread(target=srv.serve_forever, daemon=True).start()
KEY = srv.token
DATA = os.path.join(os.environ["XDG_DATA_HOME"], "openpad")
RUN = os.path.join(os.environ["XDG_RUNTIME_DIR"], "openpad")

# --------------------------------------------------------------------------- clients


def http(method, path, headers=None, body=None, host=None):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    h = {"Host": host or f"127.0.0.1:{PORT}", "Connection": "close", **(headers or {})}
    if body is not None:
        h["Content-Length"] = str(len(body))
    req = f"{method} {path} HTTP/1.1\r\n" + "".join(f"{k}: {v}\r\n" for k, v in h.items()) + "\r\n"
    s.sendall(req.encode() + (body or b""))
    data = b""
    while True:
        try:
            c = s.recv(65536)
        except socket.timeout:
            break
        if not c:
            break
        data += c
    s.close()
    head, _, rest = data.partition(b"\r\n\r\n")
    lines = head.decode(errors="replace").split("\r\n")
    code = int(lines[0].split()[1]) if lines and len(lines[0].split()) > 1 else 0
    hdrs = {ln.split(":", 1)[0].lower(): ln.split(":", 1)[1].strip() for ln in lines[1:] if ":" in ln}
    return code, hdrs, rest


def ws(path, origin=None, host=None, legacy=False):
    if not legacy and path.startswith("/ws"):
        path += ("&" if "?" in path else "?") + "v=5"  # the protocol version current clients send
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    k = base64.b64encode(os.urandom(16)).decode()
    extra = f"Origin: {origin}\r\n" if origin else ""
    s.sendall(f"GET {path} HTTP/1.1\r\nHost: {host or f'127.0.0.1:{PORT}'}\r\nUpgrade: websocket\r\n"
              f"Connection: Upgrade\r\nSec-WebSocket-Key: {k}\r\nSec-WebSocket-Version: 13\r\n{extra}\r\n".encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        c = s.recv(1)
        if not c:
            break
        buf += c
    return s, int(buf.split()[1]) if buf else 0


def send(s, payload, masked=True, binary=False):
    p = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
    n, m = len(p), os.urandom(4)
    bit = 0x80 if masked else 0
    op = 0x82 if binary else 0x81
    if n < 126:
        h = bytes([op, bit | n])
    elif n < 65536:
        h = bytes([op, bit | 126]) + struct.pack("!H", n)
    else:
        h = bytes([op, bit | 127]) + struct.pack("!Q", n)
    if masked and n:
        p = (int.from_bytes(p, "big") ^ int.from_bytes((m * (n // 4 + 1))[:n], "big")).to_bytes(n, "big")
    s.sendall(h + (m if masked else b"") + p)


def rall(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise ConnectionError
        b += c
    return b


def recv_any(s, timeout=3):
    """('text', obj) | ('binary', bytes) | ('closed', None)."""
    s.settimeout(timeout)
    while True:
        b1, b2 = rall(s, 2)
        n = b2 & 127
        if n == 126:
            n = struct.unpack("!H", rall(s, 2))[0]
        elif n == 127:
            n = struct.unpack("!Q", rall(s, 8))[0]
        d = rall(s, n)
        op = b1 & 15
        if op == 1:
            return "text", json.loads(d)
        if op == 2:
            return "binary", d
        if op == 8:
            return "closed", None


def recv_until(s, t, timeout=3):
    while True:
        kind, m = recv_any(s, timeout)
        if kind == "closed" or (kind == "text" and m.get("t") == t):
            return m or {}


def closed(s, timeout=3):
    s.settimeout(timeout)
    try:
        while True:
            d = s.recv(4096)
            if not d or d[:1] == b"\x88":
                return True
    except (socket.timeout, ConnectionError, OSError):
        return False


def mode(p):
    return stat.S_IMODE(os.stat(p).st_mode)


def wait_live_state(timeout=8):
    deadline = time.time() + timeout
    while time.time() < deadline and srv.hub.capture is not None:
        time.sleep(0.1)


# --------------------------------------------------------------------------- notebooks


def nb_with(n_pages=2, title="Physics"):
    nb = N.new_notebook(title, "letter", "Lecture 1")
    sec = nb["layout"]["sections"][0]
    for _ in range(n_pages - 1):
        p = N.blank_page(sec["id"])
        nb["pages"][p["id"]] = p
        sec["pages"].append(p["id"])
    return nb


def stroke(sid=None, n=3, **kw):
    return {"id": sid or N.new_id(), "z": time.time() * 1000, "tool": "pen", "color": "#111111", "width": 3.5,
            "pts": [[10 + i, 20 + i, 0.5] for i in range(n)], **kw}


print("== notebook merge rules")
a = nb_with(2)
p1, p2 = N.order(a)
b = copy.deepcopy(a)
a["pages"][p1]["strokes"].append(N.clean_stroke(stroke("s1")))
b["pages"][p1]["strokes"].append(N.clean_stroke(stroke("s2")))
b["pages"][p1]["gone"].append("s1")
m1, m2 = N.merge(copy.deepcopy(a), copy.deepcopy(b)), N.merge(copy.deepcopy(b), copy.deepcopy(a))
check("merge is order-independent", N.digest(m1) == N.digest(m2) and m1 == m2)
check("ink from both sides survives, removals win",
      [s["id"] for s in m1["pages"][p1]["strokes"]] == ["s2"] and m1["pages"][p1]["gone"] == ["s1"])
check("merging a copy into itself changes nothing", N.merge(copy.deepcopy(m1), copy.deepcopy(m1)) == m1)
c = copy.deepcopy(a)
c["goneP"].append(p2)
c["layout"] = {"t": N.now_ms() + 5, "sections": [{**c["layout"]["sections"][0], "pages": [p1]}]}
d = copy.deepcopy(a)
p3 = N.blank_page(d["layout"]["sections"][0]["id"], t=N.now_ms() + 9)
d["pages"][p3["id"]] = p3
m = N.merge(c, d)
check("deleted pages stay deleted", p2 not in m["pages"] and p2 not in N.order(m))
check("a page added elsewhere joins its section even under a newer layout", p3["id"] in N.order(m))
e = copy.deepcopy(a)
e["pages"][p1].update(paper="grid", t=N.now_ms() + 50)
m = N.merge(a, e)
check("page settings are last-writer-wins", m["pages"][p1]["paper"] == "grid")
check("digest changes with content", N.digest(m) != N.digest(a))
bad = N.clean_notebook({"id": "x1", "title": "<b>\x00hi", "pages": {"p": {"id": "p", "h": "1", "bg": {"pdf": "../x", "n": 1},
                        "strokes": [stroke("ok"), {"id": "../../x"}], "gone": ["ok", "a/b"]}},
                        "layout": {"t": 1, "sections": [{"id": "s", "title": "x" * 500, "pages": ["p", "p", "../"]}]}})
check("notebooks from clients are validated", bad and bad["title"] == "<b>hi" and bad["pages"]["p"]["bg"] is None
      and bad["pages"]["p"]["strokes"] == [] and bad["pages"]["p"]["gone"] == ["ok"]
      and bad["layout"]["sections"][0]["pages"] == ["p"] and len(bad["layout"]["sections"][0]["title"]) == 80, bad)

sys.path.insert(0, os.path.join(ROOT, "tests"))
import make_vectors  # noqa: E402

check("the iPad app's merge test vectors match these rules (run tests/make_vectors.py)",
      open(make_vectors.OUT).read() == make_vectors.text())

if shutil.which("node"):
    # The same random edits merged by Python and by web/model.js must agree.
    rng = random.Random(7)
    cases = []
    for _ in range(25):
        base = nb_with(rng.randint(1, 4))
        x, y = copy.deepcopy(base), copy.deepcopy(base)
        for side in (x, y):
            ids = N.order(side)
            for _ in range(rng.randint(0, 6)):
                pg = side["pages"][rng.choice(ids)]
                op = rng.random()
                if op < 0.5:
                    pg["strokes"].append(N.clean_stroke(stroke(n=rng.randint(1, 5))))
                elif op < 0.7 and pg["strokes"]:
                    s = rng.choice(pg["strokes"])
                    pg["strokes"].remove(s)
                    pg["gone"] = sorted(set(pg["gone"]) | {s["id"]})
                elif op < 0.85:
                    pg.update(paper=rng.choice(N.PAPERS), t=pg["t"] + rng.randint(1, 9))
                else:
                    np_ = N.blank_page(side["layout"]["sections"][0]["id"], t=N.now_ms() + rng.randint(0, 99))
                    side["pages"][np_["id"]] = np_
                    side["layout"] = {"t": side["layout"]["t"] + rng.randint(1, 9),
                                      "sections": [{**side["layout"]["sections"][0],
                                                    "pages": side["layout"]["sections"][0]["pages"] + [np_["id"]]}]}
        cases.append([x, y])
    expect = [(N.digest(m), N.order(m)) for m in (N.merge(copy.deepcopy(x), copy.deepcopy(y)) for x, y in cases)]
    js = ("const fs = await import('node:fs'); const m = await import(process.argv[1]);"
          "const cases = JSON.parse(fs.readFileSync(0, 'utf8')); const out = [];"
          "for (const [x, y] of cases) { const r = m.merge(m.normalize(x), m.normalize(y)); out.push([await m.digest(r), m.order(r)]); }"
          "console.log(JSON.stringify(out));")
    r = subprocess.run(["node", "--input-type=module", "-e", js, "file://" + os.path.join(ROOT, "web", "model.js")],
                       input=json.dumps(cases), capture_output=True, text=True, timeout=60)
    got = json.loads(r.stdout) if r.returncode == 0 else None
    check("web/model.js merges exactly like openpad/notebook.py",
          got is not None and [tuple(g) for g in got] == [(d_, o) for d_, o in expect], r.stderr[-400:])
else:
    print("SKIP Node not installed (JS/Python merge parity)")

# --------------------------------------------------------------------------- security

print("== access control")
code, _, body = http("GET", "/api/ping")
check("ping works without key and leaks nothing", code == 200 and b"openpad" in body and b"pid" not in body)
check("data needs the key", http("GET", "/api/info")[0] == 403)
check("wrong key rejected", http("GET", "/api/info?k=AAAAAAAAAAAAAAAAAAAAAA")[0] == 403)
check("key in query works", http("GET", f"/api/info?k={KEY}")[0] == 200)
check("key in header works", http("GET", "/api/info", {"X-OpenPad-Key": KEY})[0] == 200)
check("theme.css needs a key", http("GET", "/theme.css")[0] == 403)
check("qr needs key", http("GET", "/api/qr.svg")[0] == 403)
check("sync needs key", http("GET", "/api/sync")[0] == 403 and http("POST", "/api/sync/nb", body=b"{}")[0] == 403)
check("key is 128-bit", len(KEY) >= 22)

print("== DNS rebinding / cross-site")
check("foreign Host rejected", http("GET", f"/api/info?k={KEY}", host=f"evil.example:{PORT}")[0] == 421)
check("foreign Host rejected on pages", http("GET", "/view", host=f"attacker.test:{PORT}")[0] == 421)
check("localhost Host accepted", http("GET", "/view", host=f"localhost:{PORT}")[0] == 200)
check("ws without key rejected", ws("/ws?role=view")[1] == 403)
check("ws from foreign Origin rejected", ws(f"/ws?role=view&k={KEY}", origin="https://evil.example")[1] == 403)
check("ws from null Origin rejected", ws(f"/ws?role=view&k={KEY}", origin="null")[1] == 403)
check("sync from foreign Origin rejected",
      http("POST", f"/api/sync/nb?k={KEY}", {"Origin": "https://evil.example"}, b"{}")[0] == 403)
check("live start from foreign Origin rejected",
      http("POST", f"/api/live?k={KEY}", {"Origin": "https://evil.example"}, b'{"action":"start"}')[0] == 403)

print("== the installed app's origin (CORS)")
code, h, _ = http("OPTIONS", "/api/sync", {"Origin": APP_ORIGIN, "Access-Control-Request-Method": "POST"})
check("preflight from the app's origin allows what sync sends",
      code == 204 and h.get("access-control-allow-origin") == APP_ORIGIN
      and {"X-OpenPad-Key", "X-OpenPad-Digest", "Content-Type"} <= set(map(str.strip, h.get("access-control-allow-headers", "").split(","))))
check("preflight from other origins refused", http("OPTIONS", "/api/sync", {"Origin": "https://evil.example"})[0] == 403)
code, h, _ = http("GET", f"/api/sync?k={KEY}", {"Origin": APP_ORIGIN})
check("owner requests from the app's origin work", code == 200 and h.get("access-control-allow-origin") == APP_ORIGIN)
check("other origins get no CORS header", "access-control-allow-origin" not in http("GET", f"/api/sync?k={KEY}")[1])

print("== pages and files")
check("the QR code opens /app (a fresh address, not an old tab)", srv.pad_urls()[0].endswith(f"/app?k={KEY}") or not srv.pad_urls())
app_page = http("GET", f"/app?k={KEY}")[2]
check("the computer's copy has no web manifest, so Add to Home Screen keeps the key",
      b"app.js" in app_page and b'rel="manifest"' not in app_page
      and b'rel="manifest"' in open(os.path.join(ROOT, "web", "app.html"), "rb").read())
code, h, page = http("GET", "/view")
csp = h.get("content-security-policy", "")
check("strict CSP", "script-src 'self'" in csp and "style-src 'self'" in csp and "frame-ancestors 'none'" in csp)
check("nosniff, no-referrer, no framing",
      h.get("x-content-type-options") == "nosniff" and h.get("referrer-policy") == "no-referrer"
      and h.get("x-frame-options") == "DENY")
pages_html = [http("GET", p)[2] for p in ("/", "/view", "/join", "/setup")]
check("no inline scripts or styles (CSP-clean)", all(b"style=" not in x and b"<script>" not in x for x in pages_html))
check("pdf.js is served", http("GET", "/node_modules/pdfjs-dist/pdf.min.mjs")[0] == 200)
# The bundled npm files are exactly the published ones (sha256 of each file
# from pdfjs-dist@4.10.38 and jsqr@1.4.0; their READMEs give the package hashes).
NPM_FILES = {
    "pdfjs-dist/pdf.min.mjs": "44ec6f011027ee77791386b66c14876a5fc29e20bf0433c07c6726fff7212b72",
    "pdfjs-dist/pdf.worker.min.mjs": "bd88805178a26c729db8c0107a5b630cb900ec070f4d8c7529a3e45530afd41d",
    "jsqr/jsqr.js": "bc40c8a15196236b2314db0856f72ca0b49980cd5413b8c852a7349f5fee0859",
}
bundled = {os.path.relpath(os.path.join(d, f), os.path.join(ROOT, "web", "node_modules")).replace(os.sep, "/")
           for d, _, fs in os.walk(os.path.join(ROOT, "web", "node_modules")) for f in fs
           if not f.endswith((".md", "LICENSE"))}
check("web/node_modules holds only the two npm packages' files", bundled == set(NPM_FILES), bundled)
check("and they're unmodified", all(hashlib.sha256(open(os.path.join(ROOT, "web", "node_modules", f), "rb").read()).hexdigest() == h
                                    for f, h in NPM_FILES.items()))
for p in ("/../openpad/server.py", "/%2e%2e/openpad/server.py", "/web/../openpad/server.py", "//etc/passwd",
          "/app.html", "/server.py", "/node_modules/pdfjs-dist/LICENSE", "/node_modules/pdfjs-dist/README.md"):
    check(f"no file outside the allowlist: {p}", http("GET", p)[0] in (403, 404))
check("server header doesn't reveal Python", "python" not in http("GET", "/api/ping")[1].get("server", "").lower())

# --------------------------------------------------------------------------- live session

print("== live session: validation")
old_page, code = ws(f"/ws?role=pad&k={KEY}", legacy=True)
m = recv_until(old_page, "live")
check("a page from an older version is told to reload", code == 101 and "Reload" in m.get("error", "") and closed(old_page), m)
view, code = ws(f"/ws?role=view&k={KEY}", origin=f"http://127.0.0.1:{PORT}")
check("ws with own Origin accepted", code == 101)
st = recv_until(view, "state")
check("nothing is on screen until a notebook is opened",
      st["placeholder"] is True and st["nb"]["id"] == "nothing-shown" and st["role"] == "view")
pad, _ = ws(f"/ws?role=pad&k={KEY}")
recv_until(pad, "state")
send(pad, {"t": "begin", "page": st["page"], "s": stroke("ph1")})
time.sleep(0.3)
check("nothing can be drawn on that placeholder", "ph1" not in srv.hub.strokes)
board = nb_with(1, "Board")
http("POST", f"/api/sync/nb?k={KEY}", {"Content-Type": "application/json"}, json.dumps(board).encode())
send(pad, {"t": "open", "id": board["id"]})
st = recv_until(view, "state")
live_nb = st["nb"]
pid = st["page"]
check("opening a notebook on the iPad puts it on screen", live_nb["id"] == board["id"] and not st["placeholder"]
      and pid in live_nb["pages"])
recv_until(pad, "state")
sid = "e" + os.urandom(4).hex()
send(pad, {"t": "begin", "page": pid, "s": {"id": sid, "color": "red;background:url(x)", "width": 1e9, "by": "gfake",
           "tool": "<script>", "z": "x", "pts": [[1, 2, 0.5], ["a", 2], [1e300, 5, 9], None, "x"], "extra": 1}})
s0 = recv_until(view, "begin").get("s", {})
check("color sanitized", s0.get("color") == "#111111", s0)
check("tool sanitized", s0.get("tool") == "pen")
check("width clamped", s0.get("width") == 80)
check("unknown keys dropped, owners can't claim a guest's id", "extra" not in s0 and "by" not in s0, s0)
check("points validated and clamped", s0.get("pts") == [[1, 2, 0.5], [100000.0, 5, 1]], s0.get("pts"))
for junk in ({"t": "pts", "id": sid, "pts": {"no": 1}}, {"t": "begin", "page": pid, "s": {"id": "../../etc"}},
             {"t": "merge", "nb": {"id": "../x"}}, {"t": "goto", "page": True}, {"t": "goto", "page": "nope"},
             {"t": "remove", "page": pid, "ids": "x"}, {"t": "live", "action": "rm -rf"},
             {"t": "open", "id": "../../etc"}, {"t": "addpdf", "sha": "0" * 64, "sizes": [[1, 1]]}):
    send(pad, junk)
send(pad, b"not json")
send(pad, b"[" * 100000 + b"]" * 100000)
send(pad, {"t": "cursor", "page": pid, "x": 1, "y": 2})
m = recv_until(view, "cursor")
check("junk ignored, connection alive", m.get("x") == 1 and m.get("y") == 2, m)
big, _ = ws(f"/ws?role=pad&k={KEY}")
recv_until(big, "state")
try:
    send(big, b"x" * (3 * 1024 * 1024))
    was_closed = closed(big)
except (BrokenPipeError, ConnectionResetError):
    was_closed = True
check("oversized message closes the connection", was_closed)
um, _ = ws(f"/ws?role=pad&k={KEY}")
recv_until(um, "state")
send(um, {"t": "cursor"}, masked=False)
check("unmasked client frame closes the connection", closed(um))

print("== live session: structure")
sec = live_nb["layout"]["sections"][0]
newp = N.blank_page(sec["id"], "wide", "grid")
layout = {"t": N.now_ms(), "sections": [{**sec, "pages": sec["pages"] + [newp["id"]]}]}
send(pad, {"t": "merge", "nb": {"id": live_nb["id"], "layout": layout, "goneP": [], "pages": {newp["id"]: newp}}})
m = recv_until(view, "merge")
check("a new page reaches the share window", newp["id"] in m["nb"]["pages"] and newp["id"] in N.order(srv.hub.nb))
send(pad, {"t": "goto", "page": newp["id"]})
check("page changes are relayed", recv_until(view, "goto").get("page") == newp["id"] and srv.hub.page == newp["id"])
send(view, {"t": "goto", "page": pid})
check("the share window can turn pages too", recv_until(pad, "goto").get("page") == pid)

# --------------------------------------------------------------------------- sync

print("== sync")
nb = nb_with(3, "Calculus")
p1 = N.order(nb)[0]
nb["pages"][p1]["strokes"].append(N.clean_stroke(stroke("x1")))
code, _, body = http("POST", f"/api/sync/nb?k={KEY}", {"Content-Type": "application/json", "X-OpenPad-Digest": N.digest(nb)},
                     json.dumps(nb).encode())
res = json.loads(body)
check("a new notebook syncs", code == 200 and res["d"] == N.digest(nb) and res["nb"] is None, res)
other = copy.deepcopy(nb)
other["pages"][p1]["strokes"].append(N.clean_stroke(stroke("x2")))
other["pages"][p1]["strokes"] = [s for s in other["pages"][p1]["strokes"] if s["id"] != "x1"]
other["pages"][p1]["gone"] = ["x1"]
code, _, body = http("POST", f"/api/sync/nb?k={KEY}", {"Content-Type": "application/json", "X-OpenPad-Digest": "stale"},
                     json.dumps(other).encode())
res = json.loads(body)
merged = res["nb"]
check("a second device's copy merges", [s["id"] for s in merged["pages"][p1]["strokes"]] == ["x2"]
      and merged["pages"][p1]["gone"] == ["x1"])
listing = json.loads(http("GET", f"/api/sync?k={KEY}")[2])
check("the notebook list carries digests", any(n["id"] == nb["id"] and n["d"] == res["d"] for n in listing["notebooks"]))
check("a notebook can be fetched", json.loads(http("GET", f"/api/sync/nb/{nb['id']}?k={KEY}")[2])["title"] == "Calculus")
check("unknown notebooks 404", http("GET", f"/api/sync/nb/nope?k={KEY}")[0] == 404)
check("garbage isn't stored", http("POST", f"/api/sync/nb?k={KEY}", body=b"[1,2]")[0] == 400)
check("huge notebooks refused", http("POST", f"/api/sync/nb?k={KEY}", {"Content-Length": str(10 ** 9)})[0] == 413)

pdf = tiny_pdf(2)
sha = hashlib.sha256(pdf).hexdigest()
nb["pages"][p1]["bg"], nb["pages"][p1]["t"] = {"pdf": sha, "n": 1}, N.now_ms() + 100
res = json.loads(http("POST", f"/api/sync/nb?k={KEY}", {"Content-Type": "application/json"}, json.dumps(nb).encode())[2])
check("the server asks for files it lacks", res["missing"] == [sha], res["missing"])
check("files must match their hash", http("PUT", f"/api/asset/{'0' * 64}?k={KEY}", body=pdf)[0] == 400)
check("file upload needs the key", http("PUT", f"/api/asset/{sha}", body=pdf)[0] == 403)
check("file upload works", http("PUT", f"/api/asset/{sha}?k={KEY}", body=pdf)[0] == 200)
code, h, body = http("GET", f"/api/asset/{sha}?k={KEY}")
check("files are served with their type", code == 200 and body == pdf and h.get("content-type") == "application/pdf")
code, h, body = http("GET", f"/api/asset/{sha}?k={KEY}", {"Range": "bytes=0-7"})
check("range requests work (pdf.js reads big PDFs in parts)",
      code == 206 and body == pdf[:8] and h.get("content-range") == f"bytes 0-7/{len(pdf)}")
check("files need the key", http("GET", f"/api/asset/{sha}")[0] == 403)
check("asset names are hashes only", http("GET", f"/api/asset/..%2f..%2ftoken?k={KEY}")[0] == 404)

secid = nb["layout"]["sections"][0]["id"]
code, _, body = http("PUT", f"/api/sync/pdf/{nb['id']}/{secid}?k={KEY}", body=pdf)
out = json.loads(body).get("file", "")
check("section PDFs land in the notes folder", code == 200 and out == os.path.join(TMP, "notes", "Calculus", "Lecture 1.pdf")
      and open(out, "rb").read() == pdf, body)
check("section PDFs are owner-only", mode(out) == 0o600 and mode(os.path.dirname(out)) == 0o700)
check("only PDFs are written", http("PUT", f"/api/sync/pdf/{nb['id']}/{secid}?k={KEY}", body=b"<html>")[0] == 400)
check("unknown sections are refused", http("PUT", f"/api/sync/pdf/{nb['id']}/nosuch?k={KEY}", body=pdf)[0] == 400)
nb["layout"] = {"t": N.now_ms() + 200, "sections": [{**nb["layout"]["sections"][0], "title": "Limits/../../x"}]}
http("POST", f"/api/sync/nb?k={KEY}", {"Content-Type": "application/json"}, json.dumps(nb).encode())
code, _, body = http("PUT", f"/api/sync/pdf/{nb['id']}/{secid}?k={KEY}", body=pdf)
renamed = json.loads(body).get("file", "")
check("a renamed section replaces its old PDF, and names can't escape the folder",
      os.path.basename(renamed) == "Limits....x.pdf" and not os.path.exists(out) and os.path.dirname(renamed) == os.path.dirname(out),
      renamed)
code, _, _ = http("POST", f"/api/sync/delete?k={KEY}", {"Content-Type": "application/json"},
                  json.dumps({"id": nb["id"], "t": N.now_ms()}).encode())
res = json.loads(http("POST", f"/api/sync/nb?k={KEY}", {"Content-Type": "application/json"}, json.dumps(nb).encode())[2])
check("a deleted notebook stays deleted (another device can't bring it back)", code == 200 and "deleted" in res)
check("its folder moves to the trash", not os.path.exists(os.path.dirname(out)))

print("== the sync folder (a copy of everything)")
NOTES = os.path.join(TMP, "notes")
sig = nb_with(2, "Signals")
sig.update(folder="2025 Fall/ECE 210", metaT=N.now_ms())
pdf4 = tiny_pdf(1)
sha4 = hashlib.sha256(pdf4).hexdigest()
sp1 = N.order(sig)[0]
sig["pages"][sp1].update(bg={"pdf": sha4, "n": 1}, t=N.now_ms(), title="Fourier series")
http("PUT", f"/api/asset/{sha4}?k={KEY}", body=pdf4)
http("POST", f"/api/sync/nb?k={KEY}", {"Content-Type": "application/json"}, json.dumps(sig).encode())
srv.update_mirror(force=True)
base = os.path.join(NOTES, "2025 Fall", "ECE 210", "Signals")
copy = os.path.join(base, ".openpad", "notebook.json")
check("notebooks are copied into their folders", os.path.isfile(copy) and json.load(open(copy))["title"] == "Signals"
      and json.load(open(copy))["pages"][sp1]["title"] == "Fourier series", base)
check("with the PDFs and images their pages show", open(os.path.join(base, ".openpad", "files", sha4 + ".pdf"), "rb").read() == pdf4)
check("the copy is owner-only", mode(base) == 0o700 and mode(os.path.join(NOTES, "2025 Fall")) == 0o700 and mode(copy) == 0o600)
ssec = sig["layout"]["sections"][0]["id"]
http("PUT", f"/api/sync/pdf/{sig['id']}/{ssec}?k={KEY}", {"X-OpenPad-Digest": "0123abcd0123abcd"}, pdf4)
pdfs = json.loads(http("GET", f"/api/sync?k={KEY}")[2])["pdfs"]
check("the computer tells devices which section PDFs are current", pdfs.get(sig["id"], {}).get(ssec) == "0123abcd0123abcd")
sig.update(folder="Archive", title="Signals & Systems", metaT=N.now_ms() + 5)
http("POST", f"/api/sync/nb?k={KEY}", {"Content-Type": "application/json"}, json.dumps(sig).encode())
srv.update_mirror(force=True)
moved = os.path.join(NOTES, "Archive", "Signals & Systems")
check("renaming or refiling a notebook moves its folder, PDFs included",
      os.path.isfile(os.path.join(moved, ".openpad", "notebook.json")) and os.path.isfile(os.path.join(moved, "Lecture 1.pdf"))
      and not os.path.exists(base) and not os.path.exists(os.path.join(NOTES, "2025 Fall")), os.listdir(NOTES))
evil = nb_with(1, "../../escape")
evil.update(folder="../../../etc/x", metaT=N.now_ms())
http("POST", f"/api/sync/nb?k={KEY}", {"Content-Type": "application/json"}, json.dumps(evil).encode())
srv.update_mirror(force=True)
inside = all(os.path.realpath(os.path.join(d, f)).startswith(os.path.realpath(NOTES) + os.sep)
             for d, _, fs in os.walk(NOTES) for f in fs)
check("folder and notebook names can't escape the sync folder", inside and not os.path.exists(os.path.join(TMP, "etc")))
check("choosing the sync folder needs the key", http("POST", "/api/settings", body=b'{"syncFolder":"/tmp/x"}')[0] == 403)
for bad in ("relative/path", "/", DATA, os.path.dirname(DATA), os.path.expanduser("~")):
    code, _, body = http("POST", f"/api/settings?k={KEY}", {"Content-Type": "application/json"}, json.dumps({"syncFolder": bad}).encode())
    check(f"refuses {bad!r} as the sync folder", code == 400, body)
NOTES2 = os.path.join(TMP, "notes2")
code, _, body = http("POST", f"/api/settings?k={KEY}", {"Content-Type": "application/json"}, json.dumps({"syncFolder": NOTES2}).encode())
srv.update_mirror(force=True)
check("a new sync folder gets a fresh copy of everything", code == 200 and json.loads(body)["syncFolder"] == NOTES2
      and os.path.isfile(os.path.join(NOTES2, "Archive", "Signals & Systems", ".openpad", "notebook.json")), body)
check("and devices are asked to send the readable PDFs again",
      not any(json.loads(http("GET", f"/api/sync?k={KEY}")[2])["pdfs"].values()))
check("the old folder is left alone", os.path.isfile(os.path.join(moved, "Lecture 1.pdf")))
check("the choice is remembered", json.load(open(os.path.join(DATA, "config.json")))["syncFolder"] == NOTES2)
os.environ.pop("OPENPAD_NOTES", None)

print("== the computer's Sync button")
res = json.loads(http("POST", f"/api/sync/request?k={KEY}")[2])
check("Sync asks the connected iPad to sync", res["pads"] >= 1 and recv_until(pad, "sync-request").get("t") == "sync-request", res)
send(pad, {"t": "sync-done", "ok": True, "notebooks": 3})
m = recv_until(view, "sync-done")
time.sleep(0.3)
last = json.loads(http("GET", f"/api/info?k={KEY}")[2])["lastSync"]
check("its report reaches the share window and the bar widget", m.get("notebooks") == 3 and last["ok"] and last["notebooks"] == 3)
send(view, {"t": "sync-done", "ok": False, "notebooks": 99})
time.sleep(0.3)
check("only the iPad app can report a sync", json.loads(http("GET", f"/api/info?k={KEY}")[2])["lastSync"]["notebooks"] == 3)

# --------------------------------------------------------------------------- guests

print("== guests")
W, V = srv.guests.tokens["w"], srv.guests.tokens["v"]
check("guest links need a valid token", ws("/ws?g=AAAAAAAAAAAAAAAAAAAAAA")[1] == 403)
ALICE, MALLORY = "alice-secret-0123456789ab", "mallory-secret-0123456789"
gw, code = ws(f"/ws?g={W}&me={ALICE}")
st = recv_until(gw, "state")
ALICE_TAG = st["by"]
check("a draw link joins as a guest who can draw", code == 101 and st["role"] == "guest" and st["write"]
      and re.fullmatch(r"g[A-Za-z0-9_-]{20}", ALICE_TAG) and ALICE not in ALICE_TAG, st["by"])
gv, _ = ws(f"/ws?g={V}&me=bob-secret-0123456789abcd")
stv = recv_until(gv, "state")
check("a view link can't draw", stv["write"] is False)
send(gv, {"t": "begin", "page": pid, "s": stroke("v1")})
time.sleep(0.3)
check("view-only guests' ink is ignored", "v1" not in srv.hub.strokes)
send(gw, {"t": "begin", "page": pid, "s": stroke("g1", by="gsomeoneelse")})
m = recv_until(pad, "begin")
check("guest ink is tagged with the guest's id", m["s"]["id"] == "g1" and m["s"].get("by") == ALICE_TAG, m)
send(pad, {"t": "preview", "page": pid, "id": "pv1", "pts": [[1, 2, 0.5]]})
send(gw, {"t": "end", "id": sid})
time.sleep(0.3)
got = []
try:
    while True:
        kind, m = recv_any(pad, 0.5)
        got.append(m)
except (OSError, ConnectionError):
    pass
try:
    while True:
        kind, m = recv_any(gv, 0.5)
        got.append(m)
except (OSError, ConnectionError):
    pass
types = {x.get("t") for x in got if isinstance(x, dict)}
check("the old PencilKit preview message isn't relayed", "preview" not in types, types)
check("guests can't end the owner's strokes", "end" not in types, types)
send(gw, {"t": "pts", "id": sid, "pts": [[5, 5, 0.5]]})
send(gw, {"t": "remove", "page": pid, "ids": [sid]})
time.sleep(0.3)
check("guests can't erase or extend the owner's ink", sid in srv.hub.strokes and len(srv.hub.strokes[sid][0]["pts"]) == 2)
# Another draw guest sees Alice's tag on her stroke and tries to become her.
st_m = None
for claim in (ALICE_TAG, ALICE_TAG[1:], ALICE_TAG[1:] + "aa", "alice1", MALLORY):
    gm, _ = ws(f"/ws?g={W}&me={claim}")
    st_m = recv_until(gm, "state")
    send(gm, {"t": "remove", "page": pid, "ids": ["g1"]})
    send(gm, {"t": "pts", "id": "g1", "pts": [[9, 9, 0.5]]})
    time.sleep(0.2)
    gm.close()
    if st_m["by"] == ALICE_TAG:
        break
check("a guest can't claim another guest's identity", st_m["by"] != ALICE_TAG and "g1" in srv.hub.strokes
      and len(srv.hub.strokes["g1"][0]["pts"]) == len(stroke("g1")["pts"]), st_m["by"])
tags = set()
for _ in range(2):
    gs, _ = ws(f"/ws?g={W}&me=short")
    tags.add(recv_until(gs, "state")["by"])
    gs.close()
check("a page without a usable secret gets a new identity each time", len(tags) == 2, tags)
gw.close()
gw, _ = ws(f"/ws?g={W}&me={ALICE}")
check("the same secret keeps the same identity after reconnecting", recv_until(gw, "state")["by"] == ALICE_TAG)
send(gw, {"t": "remove", "page": pid, "ids": ["g1"]})
time.sleep(0.3)
check("guests can erase their own ink", "g1" not in srv.hub.strokes)
for msg in ({"t": "goto", "page": newp["id"]}, {"t": "live", "action": "start"},
            {"t": "merge", "nb": {"id": live_nb["id"], "title": "pwned", "metaT": N.now_ms() + 10 ** 6}},
            {"t": "open", "id": nb["id"]}, {"t": "clearguests"}):
    send(gw, msg)
time.sleep(0.4)
check("guests can't turn pages, rename, open notebooks or start window capture",
      srv.hub.page == pid and srv.hub.nb["title"] != "pwned" and srv.hub.live["state"] == "idle")
check("guests can't use owner endpoints", all(http("GET", f"{p}?g={W}")[0] == 403 for p in ("/api/info", "/api/sync", "/api/pairing", "/api/ca.crt")))
check("guests only get files of the live notebook", http("GET", f"/api/asset/{sha}?g={W}")[0] == 404)
check("guests get the theme", http("GET", f"/theme.css?g={W}")[0] == 200)
code, _, body = http("POST", f"/api/guests?k={KEY}", {"Content-Type": "application/json"}, b'{"action":"rotate"}')
check("new links disconnect current guests", code == 200 and closed(gw) and closed(gv))
check("old links stop working", ws(f"/ws?g={W}")[1] == 403 and srv.guests.check(W) is None)
W = srv.guests.tokens["w"]

print("== WebSocket limits (a guest can't exhaust the server's memory)")
from openpad.server import MAX_WS_BACKLOG, WSConn  # noqa: E402


def raw_frame(op, payload=b"", fin=True):
    m, n = os.urandom(4), len(payload)
    head = bytes([(0x80 if fin else 0) | op])
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 65536:
        head += bytes([0x80 | 126]) + struct.pack("!H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack("!Q", n)
    return head + m + bytes(b ^ m[i % 4] for i, b in enumerate(payload))


def flood(path, data):
    s, _ = ws(path)
    recv_until(s, "state")
    try:
        s.sendall(data)
    except OSError:
        pass  # the server hung up part way: good
    return s


V = srv.guests.tokens["v"]
g = flood(f"/ws?g={V}", raw_frame(0x1, b"", fin=False) + raw_frame(0x0, b"", fin=False) * 20000)
check("endless empty fragments from a view-only guest end the connection", closed(g, 5))
g = flood(f"/ws?g={V}", raw_frame(0x1, b"x", fin=False) + raw_frame(0x0, b"x", fin=False) * 20000)
check("so do endless one-byte fragments", closed(g, 5))
check("a ping split into fragments ends the connection", closed(flood(f"/ws?g={V}", raw_frame(0x9, b"hi", fin=False))))
check("so does a ping over 125 bytes", closed(flood(f"/ws?g={V}", raw_frame(0x9, b"x" * 126))))
before = {c.id for c in srv.hub.conns}
g, _ = ws(f"/ws?g={V}")
recv_until(g, "state")
conn = next(c for c in srv.hub.conns if c.id not in before)
g.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
ping = raw_frame(0x9, b"p" * 125)
worst = 0
for _ in range(40):
    try:
        g.sendall(ping * 2500)
    except OSError:
        break
    worst = max(worst, conn.out.qsize())
check("a ping flood that never reads the replies doesn't pile them up", worst <= 2, worst)
g.close()
msg = json.dumps({"t": "cursor", "page": srv.hub.page, "x": 7, "y": 8}).encode()
view.sendall(raw_frame(0x1, msg[:10], fin=False) + raw_frame(0x9, b"hi") + raw_frame(0x0, msg[10:]))
m = recv_until(pad, "cursor")
check("a message in fragments, with a ping between them, still works", m.get("x") == 7, m)

# A client that stops reading while the notebook keeps changing.
a, b = socket.socketpair()
a.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
b.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
slow = WSConn(a, a.makefile("rb"), "guest")
big = {"t": "state", "nb": "x" * (1024 * 1024)}
t = threading.Thread(target=lambda: [slow.send(big) for _ in range(40)], daemon=True)
t.start()
t.join(10)
check("a client that falls too far behind is disconnected, without blocking the sender",
      not t.is_alive() and not slow.alive and slow.backlog <= MAX_WS_BACKLOG + 2 * 1024 * 1024, (t.is_alive(), slow.alive))
a.close()
b.close()

print("== internet links (tunnel)")
srv.tunnel.url = "https://quiet-river-test.trycloudflare.com"
srv.tunnel.state = "on"
TH = "quiet-river-test.trycloudflare.com"
check("the guest page works through the tunnel", http("GET", "/join", host=TH)[0] == 200)
s, code = ws(f"/ws?g={W}&me=carol-secret-0123456789abc", origin=f"https://{TH}", host=TH)
check("guests connect through the tunnel", code == 101 and recv_until(s, "state")["role"] == "guest")
s.close()
check("the owner key never works through the tunnel",
      http("GET", f"/api/info?k={KEY}", host=TH)[0] == 404 and ws(f"/ws?role=pad&k={KEY}", host=TH)[1] == 403)
check("owner pages and APIs are hidden from the internet",
      all(http("GET", p, host=TH)[0] == 404 for p in ("/", "/view", "/setup", f"/api/sync?k={KEY}"))
      and http("POST", "/api/pair", host=TH, body=b'{"pin":"000000"}')[0] == 404)
check("the tunnel gives no key proof", "proof" not in json.loads(http("GET", "/api/ping?n=" + "ab" * 16, host=TH)[2]))
info = json.loads(http("GET", f"/api/info?k={KEY}")[2])
check("internet guest links use the tunnel", info["guests"]["iw"] == f"https://{TH}/join#w={W}")
srv.tunnel.url, srv.tunnel.state = None, "off"
check("the tunnel host is forgotten when it stops", http("GET", "/join", host=TH)[0] == 421)

print("== pairing the installed app")
info = json.loads(http("GET", f"/api/pairing?k={KEY}")[2])
check("pairing info has the computer's name and its addresses", info.get("name") and isinstance(info.get("addresses"), list)
      and re.fullmatch(r"\d{6}", info.get("pin", "")))
pin, _ = srv.pairing.current()
check("wrong PIN refused", http("POST", "/api/pair", {"Content-Type": "application/json"}, b'{"pin":"000000"}')[0] == 403
      if pin != "000000" else True)
time.sleep(1.05)
code, _, body = http("POST", "/api/pair", {"Content-Type": "application/json", "Origin": APP_ORIGIN},
                     json.dumps({"pin": pin}).encode())
check("the right PIN gives the key", code == 200 and json.loads(body)["k"] == KEY)
check("a PIN works once", srv.pairing.current()[0] != pin)
time.sleep(1.05)
check("guesses are rate-limited", [http("POST", "/api/pair", body=b'{"pin":"1"}')[0] for _ in range(2)] == [403, 403]
      and srv.pairing.tries <= 1)
check("pairing from other origins refused", http("POST", "/api/pair", {"Origin": "https://evil.example"}, b'{"pin":"1"}')[0] == 403)

from openpad.server import PIN_FAILS_PER_DAY, PIN_TRIES, Pairing  # noqa: E402


def guess(pg, pin):
    pg.last_try -= 2  # skip the one-second wait
    return pg.check(pin)


pg = Pairing()
check("no PIN works until the owner's screen shows one", not guess(pg, "000000") and not guess(pg, ""))
pin = pg.current()[0]
wrong = "%06d" % ((int(pin) + 1) % 1_000_000)
for _ in range(PIN_TRIES):
    guess(pg, wrong)
check("a PIN is dropped after a few wrong tries", not guess(pg, pin) and pg.pin == "")
check("and expired PINs don't come back on their own", pg.expires == 0)
pin = pg.current()[0]
check("the owner's screen gets a new one", re.fullmatch(r"\d{6}", pin) and guess(pg, pin))
pg = Pairing()
for _ in range(PIN_FAILS_PER_DAY):
    pin = pg.current()[0]
    guess(pg, "%06d" % ((int(pin) + 1) % 1_000_000))
check("wrong PINs are capped per day", pg.locked() and pg.current() == ("", 0) and not guess(pg, pg.pin))
pg.fails = [t - 86401 for t in pg.fails]
check("the cap lifts after a day", not pg.locked() and re.fullmatch(r"\d{6}", pg.current()[0]))
real, srv.pairing = srv.pairing, pg
pg.fails = [time.monotonic()] * PIN_FAILS_PER_DAY
code, _, body = http("POST", "/api/pair", {"Content-Type": "application/json"}, b'{"pin":"123456"}')
info = json.loads(http("GET", f"/api/pairing?k={KEY}")[2])
check("a locked computer says so (429) and shows no PIN", code == 429 and info["locked"] and info["pin"] == "", (code, info))
srv.pairing = real

print("== HTTPS on the same port")
ca_pem = os.path.join(DATA, "tls", "ca.pem")
ctx = ssl.create_default_context(cafile=ca_pem)
with socket.create_connection(("127.0.0.1", PORT), timeout=5) as raw:
    with ctx.wrap_socket(raw, server_hostname="127.0.0.1") as t:
        t.sendall(f"GET /api/sync?k={KEY} HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\nConnection: close\r\n\r\n".encode())
        resp = b""
        while chunk := t.recv(65536):
            resp += chunk
check("the server speaks HTTPS with a certificate from its own CA", resp.startswith(b"HTTP/1.1 200") and b"notebooks" in resp)
from openpad import tls  # noqa: E402

ca = srv.ca
d_, q_ = tls.new_key()
bad = tls.certificate("OpenPad server", q_, ca.issuer_cn, ca.ca_d, ca.ca_q, 30, names=["8.8.8.8", "example.com"])
bad_dir = os.path.join(TMP, "badcert")
os.makedirs(bad_dir)
open(os.path.join(bad_dir, "c.pem"), "w").write(tls.pem("CERTIFICATE", bad))
open(os.path.join(bad_dir, "k.pem"), "w").write(tls.private_key_pem(d_, q_))
sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
sctx.load_cert_chain(os.path.join(bad_dir, "c.pem"), os.path.join(bad_dir, "k.pem"))
ls = socket.socket()
ls.bind(("127.0.0.1", 0))
ls.listen()


def accept_once():
    c, _ = ls.accept()
    try:
        sctx.wrap_socket(c, server_side=True).recv(1)
    except (ssl.SSLError, OSError):
        pass


threading.Thread(target=accept_once, daemon=True).start()
try:
    with socket.create_connection(ls.getsockname(), timeout=5) as raw:
        ctx.wrap_socket(raw, server_hostname="example.com")
    constrained = False
except ssl.SSLCertVerificationError:
    constrained = True
check("the CA can't vouch for public websites (name constraints)", constrained)
check("the CA key is owner-only", mode(os.path.join(DATA, "tls", "ca-key.pem")) == 0o600)
code, h, body = http("GET", f"/api/ca.crt?k={KEY}")
check("the certificate downloads for the iPad", code == 200 and h.get("content-type") == "application/x-x509-ca-cert" and body[:1] == b"\x30")

print("== control endpoints")
check("launch code needs key header", http("POST", "/api/launch")[0] == 403)
check("launch code ignores ?k=", http("POST", f"/api/launch?k={KEY}")[0] == 403)
check("shutdown needs key header", http("POST", "/api/shutdown")[0] == 403)
check("shutdown ignores ?k=", http("POST", f"/api/shutdown?k={KEY}")[0] == 403)
code, _, body = http("POST", "/api/launch", {"X-OpenPad-Key": KEY})
lc = json.loads(body)["c"]
code, _, body = http("POST", "/api/redeem", {"Content-Type": "application/json"}, json.dumps({"c": lc}).encode())
check("launch code redeems to the key", code == 200 and json.loads(body)["k"] == KEY)
check("launch code is single-use",
      http("POST", "/api/redeem", {"Content-Type": "application/json"}, json.dumps({"c": lc}).encode())[0] == 403)
check("redeem from foreign Origin rejected",
      http("POST", "/api/redeem", {"Origin": "https://evil.example"}, b'{"c":"x"}')[0] == 403)
check("live control needs key", http("POST", "/api/live", body=b'{"action":"start"}')[0] == 403)

print("== PDFs added from the share window")
pdf3 = tiny_pdf(3)
sha3 = hashlib.sha256(pdf3).hexdigest()
http("PUT", f"/api/asset/{sha3}?k={KEY}", body=pdf3)
before = len(srv.hub.nb["layout"]["sections"])
send(view, {"t": "addpdf", "sha": sha3, "name": "Week 2.pdf", "sizes": [[612, 792]] * 3})
st = recv_until(pad, "state")
secs = st["nb"]["layout"]["sections"]
check("a PDF becomes a new section of the live notebook",
      len(secs) == before + 1 and any(s["title"] == "Week 2" and len(s["pages"]) == 3 for s in secs))
check("its pages show the PDF", st["nb"]["pages"][st["page"]]["bg"] == {"pdf": sha3, "n": 1})
gw, _ = ws(f"/ws?g={W}&me=dave-secret-0123456789abcd")
recv_until(gw, "state")
check("guests can now load that PDF", http("GET", f"/api/asset/{sha3}?g={W}")[0] == 200)
gw.close()

print("== deleting the notebook on screen")
diary = nb_with(1, "Private diary")
http("POST", f"/api/sync/nb?k={KEY}", {"Content-Type": "application/json"}, json.dumps(diary).encode())
gw, _ = ws(f"/ws?g={W}&me=erin-secret-0123456789abcd")
recv_until(gw, "state")
http("POST", f"/api/sync/delete?k={KEY}", {"Content-Type": "application/json"},
     json.dumps({"id": srv.hub.nb["id"], "t": N.now_ms()}).encode())
st = recv_until(gw, "state")
check("guests then see nothing, never another notebook",
      st["placeholder"] is True and "Private diary" not in json.dumps(st) and srv.hub.guest_assets() == set())
send(view, {"t": "addpdf", "sha": sha3, "name": "Slides.pdf", "sizes": [[960, 540]] * 2})
st = recv_until(gw, "state")
check("a PDF added with nothing on screen becomes its own notebook",
      not st["placeholder"] and st["nb"]["title"] == "Slides" and len(N.order(st["nb"])) == 2
      and srv.store.get(st["nb"]["id"]) is not None)
gw.close()
send(pad, {"t": "open", "id": "nothing-shown"})
time.sleep(0.3)
check("the placeholder can't be opened as a notebook", srv.hub.nb["id"] == st["nb"]["id"])
http("POST", f"/api/sync/delete?k={KEY}", {"Content-Type": "application/json"},
     json.dumps({"id": srv.hub.nb["id"], "t": N.now_ms()}).encode())
time.sleep(0.3)

# --------------------------------------------------------------------------- desktop annotation

print("== desktop annotation")
if not HAVE_GST:
    print("SKIP GStreamer not available")
else:
    send(pad, {"t": "live", "action": "start"})
    send(pad, {"t": "live", "action": "start"})  # a second request while picking is ignored
    seen = {"picking": False, "live": False, "frames": 0, "jpeg": False, "page": None, "current": False}
    deadline = time.time() + 8
    while time.time() < deadline and seen["frames"] < 12:
        try:
            kind, m = recv_any(pad, 2)
        except (OSError, ConnectionError):
            break
        if kind == "binary":
            seen["frames"] += 1
            seen["jpeg"] = m[:2] == b"\xff\xd8"
        elif m.get("t") == "live":
            seen["picking"] |= m.get("state") == "picking"
            seen["live"] |= m.get("state") == "live"
        elif m.get("t") == "state":
            lp = [p for p in m["nb"]["pages"].values() if p["bg"] and p["bg"].get("live")]
            if lp:
                seen["page"] = lp[0]["id"]
                seen["current"] = m["page"] == lp[0]["id"]
    check("picker requested", seen["picking"])
    check("window goes live", seen["live"])
    check("live window becomes the current page", seen["page"] and seen["current"])
    check("with nothing on screen, the window gets its own notebook", srv.hub.nb["title"] == "Window notes"
          and N.order(srv.hub.nb) == [seen["page"]])
    check("JPEG frames streamed to the iPad", seen["frames"] >= 10 and seen["jpeg"], seen["frames"])
    time.sleep(0.5)
    status = json.load(open(os.path.join(RUN, "status.json")))
    check("bar status reports live", status.get("live") == "live", status.get("live"))
    code, _, body = http("GET", f"/api/live/frame.jpg?k={KEY}")
    check("current frame available for PDF export", code == 200 and body[:2] == b"\xff\xd8")
    check("current frame needs a key", http("GET", "/api/live/frame.jpg")[0] == 403)
    time.sleep(0.8)
    late, _ = ws(f"/ws?role=view&k={KEY}")
    kind, m = recv_any(late)
    lp = [p for p in m["nb"]["pages"].values() if p["bg"] and p["bg"].get("live")][0]
    check("window resize updates the page shape", lp["h"] == 500.0, lp["h"])
    kind, _ = recv_any(late)
    while kind == "text":
        kind, _ = recv_any(late)
    check("a late joiner gets the current frame immediately", kind == "binary")
    live_id = lp["id"]
    send(pad, {"t": "live", "action": "stop"})
    end = None
    for _ in range(60):
        kind, m = recv_any(late, 6)
        if kind == "text" and m.get("t") == "live" and m.get("state") == "idle":
            end = m
        if kind == "text" and m.get("t") == "state" and end:
            break
    check("stop reports why", end and end.get("reason") == "stopped", end)
    bg = m["nb"]["pages"][live_id]["bg"]
    check("stopped window keeps its last frame as a synced image", bg and N.SHA_RE.match(bg.get("img", "")), bg)
    code, _, body = http("GET", f"/api/asset/{bg['img']}?k={KEY}")
    check("frozen frame served", code == 200 and body[:2] == b"\xff\xd8")
    check("frozen frame stored owner-only", mode(os.path.join(DATA, "assets", bg["img"])) == 0o600)

    send(pad, {"t": "live", "action": "start"})
    time.sleep(0.8)
    lp_id = srv.hub.live["page"]
    lay = srv.hub.nb["layout"]
    send(pad, {"t": "merge", "nb": {"id": srv.hub.nb["id"], "goneP": [lp_id],
               "layout": {"t": N.now_ms() + 10, "sections": [{**s, "pages": [x for x in s["pages"] if x != lp_id]} for s in lay["sections"]]}}})
    wait_live_state()
    check("deleting the live page stops capture", srv.hub.capture is None and srv.hub.live["state"] == "idle", srv.hub.live)

print("== desktop annotation through the browser (Windows/macOS)")
srv.hub._native = False  # as on Windows/macOS: the share window captures


def drain(sock, want, timeout=4):
    """Collect messages until `want(kind, msg)` is true or time runs out."""
    deadline = time.time() + timeout
    got = []
    while time.time() < deadline:
        try:
            kind, m = recv_any(sock, max(0.1, deadline - time.time()))
        except (OSError, ConnectionError):
            break
        got.append((kind, m))
        if want(kind, m):
            break
    return got


bpad, _ = ws(f"/ws?role=pad&k={KEY}")
st = recv_until(bpad, "state")
check("clients are told capture happens in the browser", st.get("capture") == "browser", st.get("capture"))
share, _ = ws(f"/ws?role=view&k={KEY}")
recv_until(share, "state")
send(bpad, {"t": "live", "action": "start"})
m = recv_until(share, "live")
check("an iPad start asks the share window for a click", m.get("state") == "needs-desktop", m)
send(bpad, {"t": "live", "action": "source", "w": 800, "h": 500})
time.sleep(0.4)
check("the iPad can't make itself the capture source", srv.hub.source is None)
send(share, {"t": "live", "action": "source", "w": 800, "h": 500})
got = drain(bpad, lambda k, m: k == "text" and m.get("t") == "live" and m.get("state") == "live")
check("a share window becomes the source and the page goes live",
      srv.hub.source is not None and any(k == "text" and m.get("state") == "live" for k, m in got))
jpeg = jpeg_frames(320, 200, 1)[0] if HAVE_GST else b"\xff\xd8\xff\xe0" + b"\0" * 64 + b"\xff\xd9"
send(share, jpeg, binary=True)
got = drain(bpad, lambda k, m: k == "binary")
check("its JPEG frames reach the iPad", any(k == "binary" and m == jpeg for k, m in got))
send(share, b"<script>alert(1)</script>", binary=True)
got = drain(bpad, lambda k, m: k == "binary", timeout=1)
check("non-JPEG data is not relayed", not any(k == "binary" for k, m in got))
other, _ = ws(f"/ws?role=view&k={KEY}")
recv_until(other, "state")
send(other, {"t": "live", "action": "source", "w": 640, "h": 480})
m = recv_until(other, "live")
check("a second source is refused", m.get("state") == "error", m)
send(share, {"t": "live", "action": "resize", "w": 1000, "h": 500})
time.sleep(0.4)
live_page = srv.hub.nb["pages"].get(srv.hub.live["page"])
check("the source can report a new window size", live_page and live_page["h"] == 500.0, live_page and live_page["h"])
pid_live = srv.hub.live["page"]
share.close()
got = drain(bpad, lambda k, m: k == "text" and m.get("t") == "live" and m.get("state") == "idle")
end = [m for k, m in got if k == "text" and m.get("t") == "live" and m.get("state") == "idle"]
check("closing the share window ends capture", end and end[0].get("reason") == "closed", end)
time.sleep(0.3)
check("and the page keeps the last frame", (srv.hub.nb["pages"][pid_live]["bg"] or {}).get("img") == hashlib.sha256(jpeg).hexdigest())
srv.hub._native = None

print("== QR codes and guest links")
from openpad import qr  # noqa: E402
from openpad.server import Guests  # noqa: E402

check("guest links are new every session", Guests(Path(DATA)).tokens != srv.guests.tokens)
if shutil.which("node"):
    # The iPad app reads the computer's code with jsQR: it must decode ours.
    url = f"http://192.168.1.20:{PORT}/app?k={KEY}"
    rows = qr.matrix(url, border=4)
    js = ("const jsQR = require(process.argv[1]); const rows = JSON.parse(require('fs').readFileSync(0, 'utf8'));"
          "const k = 6, n = rows.length * k, data = new Uint8ClampedArray(n * n * 4);"
          "for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) { const v = rows[(y / k) | 0][(x / k) | 0] === '1' ? 0 : 255;"
          "const i = (y * n + x) * 4; data[i] = data[i + 1] = data[i + 2] = v; data[i + 3] = 255; }"
          "const r = jsQR(data, n, n); console.log(r ? r.data : '');")
    r = subprocess.run(["node", "-e", js, os.path.join(ROOT, "web", "node_modules", "jsqr", "jsqr.js")],
                       input=json.dumps(rows), capture_output=True, text=True, timeout=60)
    check("the app's QR reader decodes the computer's QR code", r.stdout.strip() == url, r.stdout[-200:] + r.stderr[-300:])
else:
    print("SKIP Node not installed (QR reader check)")

print("== upgrading from Inkcast")
old = os.path.join(TMP, "legacy")
os.makedirs(old, mode=0o700)
write_private(Path(old) / "pdf-aaaaaaaaaaaa.pdf", tiny_pdf(1))
write_private(Path(old) / "img-pg2.jpg", b"\xff\xd8\xff\xd9")
write_private(Path(old) / "session.json", json.dumps({"id": "d1", "page": 0, "pdf": {"name": "Old.pdf", "rev": "aaaaaaaaaaaa"},
              "pages": [{"id": "pg1", "w": 1000, "h": 1294, "paper": "blank", "bg": {"pdf": "aaaaaaaaaaaa", "n": 1}, "pt": [612, 792],
                         "strokes": [stroke("old1")]},
                        {"id": "pg2", "w": 1000, "h": 500, "paper": "blank", "bg": {"img": "pg2"}, "pt": [600, 300], "strokes": []}]}))
st2 = Store(Path(old), Path(TMP) / "notes2")
h2 = Hub(st2, Path(old))
check("the old board becomes a notebook with its ink",
      h2.nb["title"] == "Old.pdf" and N.order(h2.nb) == ["pg1", "pg2"] and h2.nb["pages"]["pg1"]["strokes"][0]["id"] == "old1")
check("its PDF and frames become synced files",
      h2.nb["pages"]["pg1"]["bg"]["pdf"] == hashlib.sha256(tiny_pdf(1)).hexdigest() and st2.has_asset(h2.nb["pages"]["pg2"]["bg"]["img"]))
check("old files are cleaned up", not any(f.startswith(("pdf-", "img-", "session.json")) and not f.endswith(".migrated") for f in os.listdir(old)))

# --------------------------------------------------------------------------- impostor servers

print("== the CLI only gives the key to the real server")
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer  # noqa: E402

import openpad.cli as cli  # noqa: E402
from openpad.server import ping_proof  # noqa: E402

nonce = "ab" * 16
code, _, body = http("GET", f"/api/ping?n={nonce}")
check("server proves it holds the key", json.loads(body).get("proof") == ping_proof(KEY, nonce))
check("no proof without a valid challenge", "proof" not in json.loads(http("GET", "/api/ping?n=zz")[2]))
check("CLI recognizes the real server", cli.probe(PORT) == "ours")

seen_headers = []


def squatter(proof):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            seen_headers.append(dict(self.headers))
            out = {"app": "openpad", "version": "9"}
            if proof:
                out["proof"] = proof
            body = json.dumps(out).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        do_POST = do_GET

    s = ThreadingHTTPServer(("127.0.0.1", free_port()), H)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return s


for label, proof in (("no proof", None), ("a forged proof", "0" * 64)):
    fake = squatter(proof)
    fport = fake.server_address[1]
    check(f"impostor with {label} is detected", cli.probe(fport) == "other")
    try:
        cli.request(fport, "/api/launch", "POST")
        refused = False
    except SystemExit:
        refused = True
    check(f"CLI refuses to send the key to an impostor with {label}", refused)
    check(f"start doesn't treat an impostor with {label} as running",
          cli.start_background(type("A", (), {"port": fport, "host": None})()) is False)
    fake.shutdown()
check("no key was ever sent to the impostors",
      seen_headers and not any(KEY in json.dumps(h) for h in seen_headers), len(seen_headers))
check("nothing listening means not running", cli.probe(free_port()) is None)

# --------------------------------------------------------------------------- command lines

print("== secrets stay off command lines")
# Other users can read every process's arguments (/proc/<pid>/cmdline), so the
# key, launch codes and the AirPlay PIN must never be passed as arguments.
import subprocess  # noqa: E402

import openpad.cli as cli  # noqa: E402

argvs = []
real_run, real_popen = subprocess.run, subprocess.Popen


def spy_run(cmd, *a, **kw):
    argvs.append(list(cmd))
    return real_run(cmd, *a, **kw)


class SpyPopen(real_popen):
    def __init__(self, cmd, *a, **kw):
        argvs.append(list(cmd))
        super().__init__(cmd, *a, **kw)


subprocess.run, subprocess.Popen = spy_run, SpyPopen
try:
    http("GET", f"/api/qr.svg?k={KEY}")
    srv.write_status()
    import io
    real_stdout = cli.sys.stdout
    cli.sys.stdout = type("Quiet", (), {"buffer": io.BytesIO(), "write": lambda *a: None, "flush": lambda *a: None})()
    cli.print_qr(srv.pad_urls()[0] if srv.pad_urls() else f"http://127.0.0.1:{PORT}/?k={KEY}")
    opened = []
    cli.open_window = lambda url: opened.append(url)
    real_request = cli.request
    cli.request = lambda port, path, method="GET", timeout=3: {"c": srv.new_launch_code()}
    cli.cmd_open(type("A", (), {"port": PORT, "host": None})())
    cli.request = real_request
    mirror_cmd = []
    if shutil.which("uxplay") and sys.platform != "darwin":
        real_exec = os.execvp
        os.execvp = lambda f, c: mirror_cmd.extend(c)
        cli.cmd_mirror(type("A", (), {"name": "Test", "pin": "4826", "no_pin": False, "fullscreen": False,
                                      "no_audio": False, "uxplay_args": []})())
        os.execvp = real_exec
finally:
    subprocess.run, subprocess.Popen = real_run, real_popen
    cli.sys.stdout = real_stdout
check("QR codes are made in-process (no helper program sees the link)",
      not any(a and "qrencode" in a[0] for a in argvs))
check("the key never appears in a process's arguments", not any(KEY in " ".join(a) for a in argvs))
check("the browser gets a file path, not a URL with a code",
      len(opened) == 1 and opened[0].startswith("file://") and "c=" not in opened[0] and KEY not in opened[0], opened)
launcher = opened[0][len("file://"):] if opened else ""
check("launcher page is owner-only", launcher and mode(launcher) == 0o600)
if mirror_cmd:
    check("AirPlay PIN is not in UxPlay's arguments", "4826" not in " ".join(mirror_cmd), mirror_cmd)
    rc = mirror_cmd[mirror_cmd.index("-rc") + 1] if "-rc" in mirror_cmd else ""
    check("PIN goes through an owner-only UxPlay options file",
          rc and mode(rc) == 0o600 and "pin 4826" in open(rc).read())
else:
    print("SKIP uxplay not installed")

# --------------------------------------------------------------------------- files

print("== file permissions")
time.sleep(2.5)
nbfile = os.path.join(DATA, "notebooks", srv.hub.nb["id"] + ".json")
check("data dir 0700", mode(DATA) == 0o700, oct(mode(DATA)))
check("token 0600", mode(os.path.join(DATA, "token")) == 0o600)
check("guest links 0600", mode(os.path.join(DATA, "guests.json")) == 0o600)
check("notebooks 0700/0600", mode(os.path.join(DATA, "notebooks")) == 0o700 and mode(nbfile) == 0o600)
check("files 0700", mode(os.path.join(DATA, "assets")) == 0o700)
check("certificates 0700", mode(os.path.join(DATA, "tls")) == 0o700)
check("runtime dir 0700", mode(RUN) == 0o700)
check("status 0600", mode(os.path.join(RUN, "status.json")) == 0o600)

# --------------------------------------------------------------------------- releases

print("== releases (the iPad app, for SideStore)")
sys.path.insert(0, os.path.join(ROOT, "ios", "ci"))
import make_source  # noqa: E402

versions = make_source.versions()
version = versions["manifest.json"]
check("the plugin, the server and the iPad app have one version", len(set(versions.values())) == 1, versions)
check("CHANGELOG.md says what's new in it", make_source.changes(version))


def fake_ipa(name, version):
    info = {"CFBundleShortVersionString": version, "CFBundleVersion": "7", "CFBundleIdentifier": "io.github.0w3n-n.openpad",
            "CFBundleDisplayName": "OpenPad", "CFBundleName": "OpenPad", "MinimumOSVersion": "17.0",
            "NSCameraUsageDescription": "camera", "NSLocalNetworkUsageDescription": "network", "UIFileSharingEnabled": False}
    path = os.path.join(TMP, name)
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("Payload/OpenPad.app/Info.plist", plistlib.dumps(info))
        z.writestr("Payload/OpenPad.app/OpenPad", os.urandom(1000))
    return path


ipa = fake_ipa("OpenPad.ipa", version)
raw = open(ipa, "rb").read()
tag, source, notes = make_source.build(ipa, now=datetime.datetime(2026, 10, 29, 12, 0, tzinfo=datetime.timezone.utc))
app = source["apps"][0]
rel = app["versions"][0]
check("the release is tagged with the version", tag == "v" + version)
check("SideStore can check the download's size and SHA-256",
      rel["size"] == app["size"] == len(raw) and rel["sha256"] == hashlib.sha256(raw).hexdigest())
check("version, build and minimum iPadOS come from the build itself",
      rel["version"] == app["version"] == version and rel["buildVersion"] == "7" and rel["minOSVersion"] == "17.0")
check("every permission prompt is declared, and nothing else", app["appPermissions"] == {
    "entitlements": [], "privacy": {"NSCameraUsageDescription": "camera", "NSLocalNetworkUsageDescription": "network"}})
check("the download is this release's OpenPad.ipa",
      rel["downloadURL"] == app["downloadURL"] and rel["downloadURL"].endswith(f"/releases/download/{tag}/OpenPad.ipa"))
check("dates are ISO 8601 with a time zone", rel["date"] == app["versionDate"] == "2026-10-29T12:00:00Z")
check("no marketplace ID (SideStore would take it for a notarized app)", "marketplaceID" not in app)
check("the source is version 2 (SideStore checks permissions) and plain JSON",
      source["version"] == 2 and json.loads(json.dumps(source)) == source)
check("the release notes give the source's address", make_source.SOURCE_URL in notes and source["sourceURL"] == make_source.SOURCE_URL)
check("what's new has no hard line breaks",
      make_source.unwrap("One\ntwo.\n\n- a\n  b\n- c\n\n```\nkeep\n  this\n```") == "One two.\n\n- a b\n- c\n\n```\nkeep\n  this\n```"
      and rel["localizedDescription"] == make_source.unwrap(make_source.changes(version)))
try:
    make_source.build(fake_ipa("old.ipa", "0.0.1"))
    refused = ""
except ValueError as e:
    refused = str(e)
check("a build with another version is refused", "0.0.1" in refused, refused)

srv.shutdown()
srv.server_close()
print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
