"""OpenPad server: notebooks, live sessions and sync on your local network.

Standard library only. It serves the notes app and the share window, relays
pen strokes over WebSockets while a notebook is live, keeps a synced copy of
every notebook on this computer, and serves guests who were sent a link.

Security model (see SECURITY.md):
  * The owner key (128-bit, in an owner-only file) is needed for everything
    except the static app files. There is no "trusted localhost": other local
    users and web pages loaded in the desktop browser can reach 127.0.0.1 too.
  * Guests get separate, revocable tokens that can only see the live notebook
    (and draw on it, for write links). They can never read other notebooks,
    start window capture, or use the owner key's endpoints.
  * The Host header must name this machine (defeats DNS rebinding) and any
    browser Origin must be this server, or the installed app's origin for
    owner requests (defeats cross-site WebSockets/CSRF).
  * Everything a client sends is validated and rebuilt before it is stored or
    relayed, and sizes are capped.
"""

from __future__ import annotations

import base64
import bisect
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import socket
import struct
import subprocess
import sys
import threading
import time
from collections import deque
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import __version__, qr
from . import notebook as N
from .store import Store, private_dir, write_private
from .theme import Theme

WEB_DIR = Path(__file__).resolve().parent.parent / "web"
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
# The installed (offline) app. Owner requests from it are allowed cross-origin.
APP_ORIGIN = "https://0w3n-n.github.io"
APP_URL = APP_ORIGIN + "/openpad/"
# Clients send ?v= on their WebSocket. Pages from before 0.5.1 don't, and are
# told to reload (an old tab can stay open in Safari for weeks).
PROTOCOL = 5
# Shown when no notebook is on screen: at first start, and after the one on
# screen is deleted. Never stored, and read-only.
PLACEHOLDER = "nothing-shown"

# Limits. Generous for real use, small enough that a misbehaving client can't
# exhaust memory, disk, or threads.
MAX_WS_MESSAGE = 2 * 1024 * 1024
MAX_GUEST_MESSAGE = 512 * 1024
# What keeping one received frame costs beyond its payload. Counted toward the
# message limit, so floods of tiny or empty fragments hit it quickly.
WS_FRAME_COST = 64
# Unsent messages a client may fall behind by (not counting the notebook
# itself, which a newer copy replaces). Past it the client is disconnected; it
# reconnects and gets the current state.
MAX_WS_BACKLOG = 4 * 1024 * 1024
# Ink all guests together may add per guest-link session (New links resets
# it): far more than a call needs, small enough that guests can't grow the
# notebook, or the server's memory, without bound.
GUEST_INK_STROKES = 10_000
GUEST_INK_POINTS = 250_000
# Messages a newer notebook state makes redundant (see WSConn.send_state).
STATE_COVERS = {"begin", "pts", "end", "remove", "restore", "goto", "merge", "peers", "cursor"}
MAX_NOTEBOOK_BYTES = 64 * 1024 * 1024
MAX_SECTION_PDF = 400 * 1024 * 1024
MAX_WS_CLIENTS = 32
MAX_GUESTS = 20
MAX_HTTP_CONNECTIONS = 96
# A connection that hasn't shown an owner key or a guest link (pages, static
# files, pairing) must finish its request within this many seconds, and is
# closed after it. Each network address may have this many connections open
# at once, except ones with the owner key (this computer's own are exempt),
# so slow or idle connections from one device can't take every slot.
UNTRUSTED_DEADLINE = 15
MAX_CONNECTIONS_PER_ADDRESS = 12
HTTP_TIMEOUT = 20
WS_TIMEOUT = 90
WS_PING_EVERY = 25
LAUNCH_CODE_TTL = 60
PIN_TTL = 600
PIN_TRIES = 5
# Wrong PINs allowed per day before PIN pairing locks (the QR code still works).
# With one PIN live at a time, guessing a 6-digit PIN stays out of reach.
PIN_FAILS_PER_DAY = 20

PAGES = {"/": "app.html", "/app": "app.html", "/view": "view.html", "/join": "join.html", "/setup": "setup.html"}
TYPES = {".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8",
         ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml", ".png": "image/png",
         ".webmanifest": "application/manifest+json"}
# Tests: check every state the server sends against the notebook it describes.
CHECK_STATE = bool(os.environ.get("OPENPAD_CHECK_STATE"))
GUEST_PATHS = {"/join", "/ws", "/theme.css", "/api/live/frame.jpg", "/api/ping"}


def static_files():
    """The only files served from web/: an allowlist built at startup, not a
    path lookup, so nothing outside it (or a symlink) can be reached."""
    out = {}
    for f in WEB_DIR.rglob("*"):
        rel = f.relative_to(WEB_DIR).as_posix()
        if f.is_file() and not f.is_symlink() and f.suffix in TYPES and re.fullmatch(r"[a-z0-9._/-]+", rel):
            out["/" + rel] = (f, TYPES[f.suffix])
    return out


STATIC = static_files()

# --------------------------------------------------------------------------- paths


WINDOWS = os.name == "nt"


def _migrated(old: Path, new: Path) -> Path:
    """OpenPad used to be called Inkcast: move its data (key, board) over once."""
    if not new.exists() and old.is_dir():
        try:
            os.replace(old, new)
        except OSError:
            pass
    return private_dir(new)


def data_dir() -> Path:
    if WINDOWS:
        base = Path(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~/AppData/Local"))
        return _migrated(base / "Inkcast", base / "OpenPad")
    if sys.platform == "darwin" and "XDG_DATA_HOME" not in os.environ:
        base = Path(os.path.expanduser("~/Library/Application Support"))
    else:
        base = Path(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"))
    return _migrated(base / "inkcast", base / "openpad")


def runtime_dir() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR")
    if base and os.path.isdir(base):
        return private_dir(Path(base) / "openpad")
    return private_dir(data_dir() / "run")


def load_secret(store: Path, name: str) -> str:
    f = store / name
    try:
        value = f.read_text().strip()
        if re.fullmatch(r"[A-Za-z0-9_-]{22,64}", value):
            if not WINDOWS:
                os.chmod(f, 0o600)
            return value
    except OSError:
        pass
    value = secrets.token_urlsafe(16)  # 128 bits
    write_private(f, value)
    return value


def load_token(store: Path) -> str:
    return load_secret(store, "token")


def ping_proof(key: str, nonce: str) -> str:
    return hmac.new(key.encode(), b"openpad-ping:" + nonce.encode(), hashlib.sha256).hexdigest()


def launcher_path(code: str) -> Path:
    """Owner-only page that hands a one-time code to the browser (see cli.cmd_open)."""
    return runtime_dir() / f"open-{hashlib.sha256(code.encode()).hexdigest()[:20]}.html"


GUEST_SECRET_RE = re.compile(r"[A-Za-z0-9_-]{22,64}")


def guest_tag(key: str, secret: str) -> str:
    """A guest's public ink tag (the "by" on their strokes, which every guest
    sees): a keyed hash of the private secret their page keeps. Seeing someone's
    tag doesn't let you connect as them, and the same secret keeps the same tag
    across reconnects, so guests can still erase their own ink."""
    mac = hmac.new(key.encode(), b"openpad-guest:" + secret.encode(), hashlib.sha256).digest()
    return "g" + base64.urlsafe_b64encode(mac).decode()[:20]


def dumps(obj) -> bytes:
    return json.dumps(obj, separators=(",", ":")).encode()


def _loopback(addr: str) -> bool:
    try:
        return ipaddress.ip_address(addr.split("%")[0]).is_loopback
    except ValueError:
        return False


def same(a: str, b: str) -> bool:
    return bool(a) and bool(b) and hmac.compare_digest(a.encode(), b.encode())


# --------------------------------------------------------------------------- WebSocket


class WSConn:
    def __init__(self, sock, rfile, role, write=False, by=None):
        self.sock = sock
        self.rfile = rfile
        self.role = role  # "pad" (the notes app), "view" (share window) or "guest"
        self.owner = role in ("pad", "view")
        self.write = self.owner or write
        self.by = by  # guests: the id their strokes carry
        self.limit = MAX_WS_MESSAGE if self.owner else MAX_GUEST_MESSAGE
        self.id = N.new_id()
        self.told_full = False  # guests: told the guest ink budget is used up
        # Frames waiting for the writer: (parts, size, kind), where kind is
        # "state" (the whole notebook), "op" (covered by a newer state) or "msg".
        self.pending = deque()
        self.backlog = 0  # bytes waiting, not counting a state
        self.busy = False  # the writer is sending a frame
        self.cond = threading.Condition()
        self.alive = True
        threading.Thread(target=self._writer, daemon=True).start()

    def _writer(self):
        while True:
            with self.cond:
                while self.alive and not self.pending:
                    self.cond.wait()
                if not self.alive:
                    return
                parts, size, kind = self.pending.popleft()
                if kind != "state":
                    self.backlog -= size
                self.busy = True
            try:
                for part in parts:  # big parts are shared with other connections, never copied
                    self.sock.sendall(part)
            except OSError:
                with self.cond:
                    self.alive = False
                return
            finally:
                with self.cond:
                    self.busy = False

    @staticmethod
    def _head(opcode, n) -> bytes:
        if n < 126:
            return struct.pack("!BB", 0x80 | opcode, n)
        if n < 65536:
            return struct.pack("!BBH", 0x80 | opcode, 126, n)
        return struct.pack("!BBQ", 0x80 | opcode, 127, n)

    @classmethod
    def _frame(cls, opcode, payload: bytes) -> bytes:
        return cls._head(opcode, len(payload)) + payload

    def _queue(self, payload, opcode=0x1, kind="msg", keep=None):
        """Queue one frame made of `payload` parts (bytes). With `keep`, the frame
        is skipped when more than that many are already waiting (video frames,
        pongs). A state replaces waiting ops and older states, which it already
        includes. A client more than MAX_WS_BACKLOG behind is disconnected."""
        frame, small = [], [self._head(opcode, sum(map(len, payload)))]
        for part in payload:  # join small parts; keep big (shared) ones as they are
            if len(part) < 256:
                small.append(part)
                continue
            if small:
                frame.append(b"".join(small))
                small = []
            frame.append(part)
        if small:
            frame.append(b"".join(small))
        size = sum(map(len, frame))
        behind = False
        with self.cond:
            if not self.alive or (keep is not None and len(self.pending) > keep):
                return
            if kind == "state":
                self.pending = deque(e for e in self.pending if e[2] == "msg")
                self.backlog = sum(e[1] for e in self.pending)
            elif self.backlog and self.backlog + size > MAX_WS_BACKLOG:
                behind = True
            if not behind:
                self.pending.append((frame, size, kind))
                if kind != "state":
                    self.backlog += size
                self.cond.notify()
        if behind:
            self.close()

    def send(self, obj):
        if self.alive:
            self.send_encoded(dumps(obj), obj.get("t"))

    def send_encoded(self, data: bytes, t=None):
        """A message already encoded (broadcasts encode once for everyone)."""
        self._queue([data], kind="op" if t in STATE_COVERS else "msg")

    def send_state(self, parts):
        self._queue(parts, kind="state")

    def send_binary(self, data: bytes):
        """Send a video frame, or drop it if this client is still busy with older ones."""
        self._queue([data], opcode=0x2, kind="op", keep=2)

    def ping(self):
        self._queue([], opcode=0x9)

    def close(self):
        with self.cond:
            was_alive, idle = self.alive, not self.busy and not self.pending
            self.alive = False
            self.pending.clear()
            self.cond.notify_all()
        if was_alive:
            try:
                if idle:  # the writer isn't mid-frame; a full socket buffer can't hold us long
                    self.sock.settimeout(1)
                    self.sock.sendall(self._frame(0x8, b""))
            except OSError:
                pass
            try:
                self.sock.shutdown(socket.SHUT_RDWR)  # also ends the reader (kicked guests)
            except OSError:
                pass

    def _read(self, n):
        buf = self.rfile.read(n)
        if len(buf) < n:
            raise ConnectionError("eof")
        return buf

    def _payload(self, n):
        mask = self._read(4)
        if not n:
            return b""
        data, key = self._read(n), (mask * (n // 4 + 1))[:n]
        return (int.from_bytes(data, "big") ^ int.from_bytes(key, "big")).to_bytes(n, "big")

    def recv(self):
        """The next message: str (text), bytes (binary), or None when the socket closes."""
        parts = []
        size = 0
        kind = None
        while True:
            b1, b2 = self._read(2)
            fin, opcode = b1 & 0x80, b1 & 0x0F
            if not b2 & 0x80:
                raise ConnectionError("client frames must be masked")
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._read(8))[0]
            if opcode >= 0x8:
                # Control frames are small and never fragmented (RFC 6455, 5.5).
                if n > 125 or not fin or opcode > 0xA:
                    raise ConnectionError("bad control frame")
                data = self._payload(n)
                if opcode == 0x8:
                    return None
                if opcode == 0x9:
                    self._queue([data], opcode=0xA, keep=0)  # no pong backlog for a client that doesn't read
                continue
            size += n + WS_FRAME_COST
            if size > self.limit:
                raise ConnectionError("message too large")
            if opcode not in (0x0, 0x1, 0x2) or (opcode == 0x0) == (kind is None):
                raise ConnectionError("unsupported frame")
            data = self._payload(n)
            kind = kind or opcode
            parts.append(data)
            if fin:
                data = b"".join(parts)
                return data.decode("utf-8", "replace") if kind == 0x1 else data


# --------------------------------------------------------------------------- Live session


class Hub:
    """The live session: one notebook on screen, shared by the notes app, the
    share window and guests. Its notebook is the store's own copy, so live
    edits and sync see the same data. Every mutation holds self.lock."""

    def __init__(self, store: Store, data: Path, on_change=None):
        self.store = store
        self.data = data
        self.lock = threading.RLock()
        self.conns: list[WSConn] = []
        self.on_change = on_change or (lambda: None)
        self.live = {"state": "idle", "page": None}
        self.capture = None  # native capture (Linux portal), or
        self.source = None   # a share window streaming frames it captured in the browser
        self.frame = None
        self._native = None
        self.nb = None
        self.page = None
        self.on_sync = lambda report: None  # an iPad finished a sync it was asked for
        self.guest_strokes = self.guest_points = 0  # guest ink this session (see GUEST_INK_*)
        self.state_mismatches = 0  # OPENPAD_CHECK_STATE (tests): states that differed from the notebook
        self._pick_initial()

    def native_capture(self):
        """Linux with the portal/GStreamer stack captures windows itself; elsewhere
        (Windows, macOS) the share window captures them through the browser."""
        if self._native is None:
            from .capture import missing_dependencies
            self._native = sys.platform.startswith("linux") and not missing_dependencies()
        return self._native

    def capture_mode(self):
        return "native" if self.native_capture() else "browser"

    # ------------------------------------------------------------- notebook on screen

    def _pick_initial(self):
        migrated = self.store.migrate_legacy()
        try:
            last = json.loads((self.data / "live.json").read_text())
        except (OSError, ValueError):
            last = {}
        nb = None
        for nid in (migrated, last.get("nb") if isinstance(last, dict) else None):
            nb = nb or (self.store.get(nid) if nid else None)
        if not nb:
            # Never fall back to some other notebook: guests would see it.
            return self._show_nothing()
        self._set(nb, last.get("page") if isinstance(last, dict) else None)
        # A window that was live when the server stopped is gone now.
        for p in nb["pages"].values():
            if p["bg"] and p["bg"].get("live"):
                p["bg"], p["t"] = None, N.now_ms()
                self._touch(p)
                self._changed()

    @property
    def placeholder(self):
        return self.nb["id"] == PLACEHOLDER

    def _show_nothing(self):
        nb = N.new_notebook("Nothing shown yet", "wide", "", "blank")
        nb["id"] = PLACEHOLDER
        self.nb = nb
        self.page = N.order(nb)[0]
        self._index()
        write_private(self.data / "live.json", json.dumps({"nb": None}))

    def _fresh(self, title, section_title, pages, sec):
        """A new notebook (when there's nothing on screen to add pages to)."""
        t = N.now_ms()
        nb = N.finish({"v": 1, "id": N.new_id(), "title": title, "size": "wide", "folder": "", "metaT": t, "created": t,
                       "layout": {"t": t, "sections": [{"id": sec, "title": section_title, "pages": list(pages)}]},
                       "goneP": [], "pages": dict(pages)})
        self._set(self.store.put(nb), next(iter(pages)))
        return self.nb

    def _set(self, nb, page=None):
        self.nb = nb
        order = N.order(nb)
        self.page = page if page in nb["pages"] else (order[0] if order else None)
        self._index()
        write_private(self.data / "live.json", json.dumps({"nb": nb["id"], "page": self.page}))

    def _index(self):
        self.strokes = {s["id"]: (s, p) for p in self.nb["pages"].values() for s in p["strokes"]}
        self._pages_json = {}  # page id -> its encoded JSON, shared by every connection's state

    def _touch(self, page):
        """A page changed in place: encode it afresh for the next state."""
        self._pages_json.pop(page["id"], None)

    def _changed(self):
        self.store.touch(self.nb["id"])

    def _ensure_page(self):
        if self.page not in self.nb["pages"]:
            order = N.order(self.nb)
            self.page = order[0] if order else None

    def notebook_changed(self, nid):
        """Sync merged a new copy of a notebook; refresh viewers if it's on screen."""
        with self.lock:
            if self.nb and self.nb["id"] == nid:
                self._index()
                self._ensure_page()
                self.send_state()

    def notebook_deleted(self, nid):
        with self.lock:
            if self.nb and self.nb["id"] == nid:
                self.live_stop()
                self._show_nothing()
                self.send_state()

    def guest_assets(self):
        with self.lock:
            return N.assets(self.nb)

    # ------------------------------------------------------------- connections

    def peers(self):
        return {"pads": sum(c.role == "pad" for c in self.conns),
                "views": sum(c.role == "view" for c in self.conns),
                "guests": sum(c.role == "guest" for c in self.conns)}

    def _nb_parts(self):
        """The notebook on screen as JSON, in parts. Each page's part is encoded
        once and shared by every connection until that page changes, so viewers
        (even ones that stop reading) don't each hold a copy of the notebook.
        Everything that changes a page in place calls _touch; anything bigger
        goes through _index, which starts afresh."""
        nb, cache = self.nb, self._pages_json
        parts = [dumps({k: v for k, v in nb.items() if k != "pages"})[:-1] + b',"pages":{']
        for i, (pid, page) in enumerate(nb["pages"].items()):
            if i:
                parts.append(b",")
            piece = cache.get(pid)
            if piece is None:
                piece = cache[pid] = dumps(pid) + b":" + dumps(page)
            parts.append(piece)
        parts.append(b"}}")  # closes "pages", then the notebook
        if CHECK_STATE and json.loads(b"".join(parts)) != json.loads(dumps(nb)):
            self.state_mismatches += 1
        return parts

    def _state(self, conn, nb_parts):
        rest = {"page": self.page, "placeholder": self.placeholder, "live": self.live, "capture": self.capture_mode(),
                "you": conn.id, "role": conn.role, "write": conn.write, "by": conn.by, **self.peers()}
        return [b'{"t":"state","nb":', *nb_parts, b"," + dumps(rest)[1:]]

    def join(self, conn) -> bool:
        with self.lock:
            if len(self.conns) >= MAX_WS_CLIENTS or \
                    (conn.role == "guest" and self.peers()["guests"] >= MAX_GUESTS):
                return False
            self.conns.append(conn)
            conn.send_state(self._state(conn, self._nb_parts()))
            if self.frame and self.live["state"] == "live":
                conn.send_binary(self.frame)
            self.broadcast({"t": "peers", **self.peers()})
        self.on_change()
        return True

    def leave(self, conn):
        with self.lock:
            if conn in self.conns:
                self.conns.remove(conn)
            if conn is self.source:
                self._source_end("closed")
            self.broadcast({"t": "peers", **self.peers()})
            if conn.role == "pad":
                self.broadcast({"t": "cursor", "hide": True, "from": conn.id})
        conn.close()
        self.on_change()

    def request_sync(self):
        """The computer's Sync button: ask connected notes apps to sync now."""
        with self.lock:
            pads = [c for c in self.conns if c.role == "pad"]
        for c in pads:
            c.send({"t": "sync-request"})
        return len(pads)

    def kick_guests(self):
        """New links: everyone on the old ones leaves, and guests get a fresh ink budget."""
        with self.lock:
            guests = [c for c in self.conns if c.role == "guest"]
            self.guest_strokes = self.guest_points = 0
        for c in guests:
            c.close()

    def broadcast(self, msg, skip=None):
        data = dumps(msg)  # encoded once, shared by every connection's queue
        for c in list(self.conns):
            if c is not skip:
                c.send_encoded(data, msg.get("t"))

    def ping_all(self):
        for c in list(self.conns):
            c.ping()

    def send_state(self):
        with self.lock:
            nb_parts = self._nb_parts()
            for c in list(self.conns):
                c.send_state(self._state(c, nb_parts))
        self.on_change()

    # ------------------------------------------------------------- messages
    # Every relayed message is rebuilt from validated fields.

    def handle(self, conn, msg):
        t = msg.get("t")
        with self.lock:
            nb = self.nb
            if self.placeholder and t in ("begin", "pts", "end", "remove", "restore", "merge", "clearguests"):
                return  # nothing to draw on: the iPad opens a notebook first
            page = nb["pages"].get(msg.get("page")) if isinstance(msg.get("page"), str) else None
            out = None
            if t == "begin" and page and conn.write:
                s = N.clean_stroke(msg.get("s"))
                if not s or s["id"] in self.strokes or s["id"] in page["gone"] \
                        or len(page["strokes"]) >= N.MAX_STROKES_PER_PAGE:
                    return
                s.pop("by", None)
                if conn.by:
                    if not self._guest_ink(conn, 1, len(s["pts"])):
                        return
                    s["by"] = conn.by
                page["strokes"].append(s)
                self.strokes[s["id"]] = (s, page)
                self._touch(page)
                out = {"t": "begin", "page": page["id"], "s": s}
            elif t == "pts" and conn.write:
                s, spage = self.strokes.get(N.clean_id(msg.get("id")) or "", (None, None))
                if not s or s.get("by") != conn.by:
                    return
                pts = N.clean_points(msg.get("pts"), N.MAX_POINTS_PER_STROKE - len(s["pts"]))
                if not pts or (conn.by and not self._guest_ink(conn, 0, len(pts))):
                    return
                s["pts"].extend(pts)
                self._touch(spage)
                out = {"t": "pts", "id": s["id"], "pts": pts}
            elif t == "end" and conn.write:
                sid = N.clean_id(msg.get("id"))
                s, _ = self.strokes.get(sid or "", (None, None))
                if not s or s.get("by") != conn.by:
                    return
                out = {"t": "end", "id": sid}
            elif t == "remove" and page and conn.write:
                ids = msg.get("ids") if isinstance(msg.get("ids"), list) else []
                ids = {i for i in ids[:N.MAX_IDS_PER_MESSAGE] if N.clean_id(i)}
                # Guests can only erase their own ink.
                gone = [s["id"] for s in page["strokes"] if s["id"] in ids and (conn.owner or s.get("by") == conn.by)]
                if not gone:
                    return
                gs = set(gone)
                page["strokes"] = [s for s in page["strokes"] if s["id"] not in gs]
                for i in gone:  # kept sorted (the sync digest relies on it) without re-sorting it all
                    at = bisect.bisect_left(page["gone"], i)
                    if at == len(page["gone"]) or page["gone"][at] != i:
                        page["gone"].insert(at, i)
                    self.strokes.pop(i, None)
                self._touch(page)
                out = {"t": "remove", "page": page["id"], "ids": gone}
            elif t == "restore" and page and conn.write:
                strokes = msg.get("strokes") if isinstance(msg.get("strokes"), list) else []
                added = []
                for raw in strokes[:N.MAX_IDS_PER_MESSAGE]:
                    s = N.clean_stroke(raw)
                    if not s or s["id"] in self.strokes or s["id"] in page["gone"] \
                            or len(page["strokes"]) >= N.MAX_STROKES_PER_PAGE:
                        continue
                    if not conn.owner:
                        if not self._guest_ink(conn, 1, len(s["pts"])):
                            break
                        s["by"] = conn.by
                    page["strokes"].append(s)
                    self.strokes[s["id"]] = (s, page)
                    added.append(s)
                if not added:
                    return
                page["strokes"].sort(key=lambda s: (s["z"], s["id"]))
                self._touch(page)
                out = {"t": "restore", "page": page["id"], "strokes": added}
            elif t == "goto" and page and conn.owner:
                self.page = page["id"]
                write_private(self.data / "live.json", json.dumps({"nb": nb["id"], "page": self.page}))
                out = {"t": "goto", "page": page["id"]}
            elif t == "merge" and conn.owner:
                part = N.clean_notebook(msg.get("nb"), partial=True)
                if not part or part["id"] != nb["id"]:
                    return
                if self.live["page"] in part["goneP"]:
                    self.live_stop()
                self.store.put(part)  # merges into self.nb in place
                self._index()
                self._ensure_page()
                out = {"t": "merge", "nb": part}
            elif t == "open" and conn.role == "pad":
                # The notes app opened a notebook (already synced over HTTP): put it on screen.
                target = self.store.get(N.clean_id(msg.get("id")) or "")
                if not target:
                    return conn.send({"t": "error", "error": "That notebook hasn't synced to the computer yet."})
                if target is not nb:
                    self.live_stop()
                self._set(target, msg.get("page") if isinstance(msg.get("page"), str) else None)
                self.send_state()
                return
            elif t == "hide" and conn.role == "pad":
                # "Show on the computer" is off in the notes app: take its notebook
                # off the screen, so edits that later sync aren't shown to anyone.
                if not self.placeholder and N.clean_id(msg.get("id")) == nb["id"]:
                    self.live_stop()
                    self._show_nothing()
                    self.send_state()
                return
            elif t == "sync-done" and conn.role == "pad":
                report = {"time": int(time.time()), "ok": msg.get("ok") is True,
                          "notebooks": int(N.num(msg.get("notebooks"), 0, 100000) or 0),
                          "error": N.clean_text(msg.get("error"), "", 300)}
                self.broadcast({"t": "sync-done", **report}, skip=conn)
                self.on_sync(report)
                return
            elif t == "cursor" and conn.owner:
                x, y = N.num(msg.get("x"), -1e5, 1e5), N.num(msg.get("y"), -1e5, 1e5)
                if msg.get("hide") is True or not page or x is None or y is None:
                    out = {"t": "cursor", "hide": True}
                else:
                    out = {"t": "cursor", "page": page["id"], "x": round(x, 1), "y": round(y, 1)}
                out["from"] = conn.id
                self.broadcast(out, skip=conn)
                return  # ephemeral: not stored
            elif t == "live" and conn.owner:
                return self._live_message(conn, msg)
            elif t == "addpdf" and conn.owner:
                return self._add_pdf(msg)
            elif t == "clearguests" and conn.owner:
                pages = [page] if page else list(nb["pages"].values())
                for p in pages:
                    ids = [s["id"] for s in p["strokes"] if s.get("by")]
                    if ids:
                        self.handle(conn, {"t": "remove", "page": p["id"], "ids": ids})
                        conn.send({"t": "remove", "page": p["id"], "ids": ids})
                return
            if out is None:
                return
            self._changed()
            out["from"] = conn.id
            self.broadcast(out, skip=conn)
        if t == "goto":
            self.on_change()

    def _guest_ink(self, conn, strokes, points):
        """Count a guest's new ink against the session's budget (False: over it)."""
        if self.guest_strokes + strokes > GUEST_INK_STROKES or self.guest_points + points > GUEST_INK_POINTS:
            if not conn.told_full:
                conn.told_full = True
                conn.send({"t": "error", "error": "Guests have added as much ink as one session allows. "
                                                  "The presenter can start a new one with New links."})
            return False
        self.guest_strokes += strokes
        self.guest_points += points
        return True

    def _add_pdf(self, msg):
        """A PDF opened in the share window: its pages become a new section
        after the current one (the share window already uploaded the file)."""
        sha = msg.get("sha")
        sizes = msg.get("sizes") if isinstance(msg.get("sizes"), list) else []
        if not self.store.has_asset(sha) or not sizes:
            return
        t = N.now_ms()
        sec = N.new_id()
        pages = {}
        for i, wh in enumerate(sizes[:N.MAX_PAGES]):
            w = N.num(wh[0], 1, 1e5) if isinstance(wh, list) and len(wh) == 2 else None
            h = N.num(wh[1], 1, 1e5) if w else None
            if not h:
                continue
            p = N.blank_page(sec, "letter", "blank", t)
            p.update({"h": round(N.PAGE_W * h / w, 2), "pt": [round(w, 2), round(h, 2)], "bg": {"pdf": sha, "n": i + 1}})
            pages[p["id"]] = p
        if not pages:
            return
        title = N.clean_text(msg.get("name"), "PDF", 80).removesuffix(".pdf") or "PDF"
        if self.placeholder:
            self._fresh(title, title, pages, sec)
            return self.send_state()
        layout = [dict(s, pages=list(s["pages"])) for s in self.nb["layout"]["sections"]]
        cur = next((i for i, s in enumerate(layout) if self.page in s["pages"]), len(layout) - 1)
        layout.insert(cur + 1, {"id": sec, "title": title, "pages": list(pages)})
        self.store.put({**self.nb, "layout": {"t": t, "sections": layout}, "pages": {**self.nb["pages"], **pages}})
        self._index()
        self.page = next(iter(pages))
        self.send_state()

    # ------------------------------------------------------------- desktop annotation

    def _live_message(self, conn, msg):
        action = msg.get("action")
        if action == "start":
            if self.native_capture():
                self.live_start()
            elif not (self.capture or self.source):
                # The browser only opens its picker after a click there,
                # so ask the share window(s) to show a button for it.
                self.broadcast({"t": "live", "state": "needs-desktop"})
        elif action == "stop":
            self.live_stop()
        elif action in ("source", "resize") and conn.role == "view":
            w, h = N.num(msg.get("w"), 16, 16384), N.num(msg.get("h"), 16, 16384)
            if w is None or h is None:
                return
            if action == "resize":
                if conn is self.source:
                    self._live_resized(int(w), int(h))
            elif self.capture or self.source:
                conn.send({"t": "live", "state": "error", "error": "Another window is already live."})
            else:
                self.source = conn
                self._live_started(int(w), int(h))

    def live_start(self):
        """Ask the desktop to pick a window; it becomes a live page when chosen."""
        from .capture import WindowCapture, missing_dependencies

        with self.lock:
            if self.capture:
                return
            missing = missing_dependencies()
            if missing:
                self.broadcast({"t": "live", "state": "error",
                                "error": "Window capture needs " + ", ".join(missing) + ". Run setup on the computer."})
                return
            self.live = {"state": "picking", "page": None}
            self.capture = WindowCapture(self._live_started, self._live_frame, self._live_resized, self._live_ended)
            self.capture.start()
        self.broadcast({"t": "live", "state": "picking"})
        self.on_change()

    def live_stop(self, wait=0.0):
        with self.lock:
            cap = self.capture
            if self.source:
                self._source_end("stopped")
                return
        if cap:
            cap.stop()
            if wait:
                cap.thread.join(wait)  # let it save the last frame

    def _live_started(self, w, h):
        with self.lock:
            if len(self.nb["pages"]) >= N.MAX_PAGES:
                self.live_stop()
                return
            t = N.now_ms()
            sec_id = N.new_id()
            if not self.placeholder:
                layout = [dict(s, pages=list(s["pages"])) for s in self.nb["layout"]["sections"]]
                sec_id = next((s for s in layout if self.page in s["pages"]), layout[-1])["id"]
            p = N.blank_page(sec_id, "wide", "blank", t)
            p.update({"h": round(N.PAGE_W * h / w, 2), "pt": [round(w * 0.75, 2), round(h * 0.75, 2)], "bg": {"live": True}})
            if self.placeholder:
                self._fresh("Window notes", "Windows", {p["id"]: p}, sec_id)
            else:
                sec = next(s for s in layout if s["id"] == sec_id)
                at = sec["pages"].index(self.page) + 1 if self.page in sec["pages"] else len(sec["pages"])
                sec["pages"].insert(at, p["id"])
                self.store.put({**self.nb, "layout": {"t": t, "sections": layout}, "pages": {**self.nb["pages"], p["id"]: p}})
                self._index()
            self.page = p["id"]
            self.live = {"state": "live", "page": p["id"]}
        self.send_state()
        self.broadcast({"t": "live", "state": "live"})
        self.on_change()

    def handle_frame(self, conn, data):
        """A JPEG frame from the share window that is capturing a window."""
        if conn is self.source and data[:3] == b"\xff\xd8\xff":
            self._live_frame(data)

    def _source_end(self, reason):
        with self.lock:
            src = self.source
            self.source = None
        if src is not None:
            src.send({"t": "live", "state": "source-stop"})
            self._live_ended(reason)

    def _live_frame(self, jpeg):
        self.frame = jpeg
        for c in list(self.conns):
            c.send_binary(jpeg)

    def _live_resized(self, w, h):
        with self.lock:
            page = self.nb["pages"].get(self.live["page"])
            if not page or self.placeholder:
                return
            page["h"] = round(N.PAGE_W * h / w, 2)
            page["pt"] = [round(w * 0.75, 2), round(h * 0.75, 2)]
            page["t"] = N.now_ms()
            self._touch(page)
            self._changed()
        self.send_state()

    def _live_ended(self, reason):
        with self.lock:
            page = self.nb["pages"].get(self.live["page"]) if not self.placeholder else None
            if page:
                # The last frame stays on the page, as an image every device syncs.
                page["bg"] = {"img": self.store.add_asset_bytes(self.frame)} if self.frame else None
                page["t"] = N.now_ms()
                self._touch(page)
                self._changed()
            self.capture = None
            self.frame = None
            self.live = {"state": "idle", "page": None}
        msg = {"t": "live", "state": "idle", "reason": reason if reason in ("stopped", "cancelled", "closed") else "error"}
        if msg["reason"] == "error":
            msg["error"] = str(reason)[:300]
        self.broadcast(msg)
        self.send_state()
        self.on_change()


# --------------------------------------------------------------------------- guests & pairing


class Guests:
    """Two revocable links: "w" lets guests draw, "v" only lets them watch."""

    def __init__(self, store: Path):
        # Links last one session: a link sent last week shouldn't still work.
        self.file = store / "guests.json"
        self.rotate()

    def rotate(self):
        self.tokens = {"w": secrets.token_urlsafe(16), "v": secrets.token_urlsafe(16)}
        write_private(self.file, json.dumps(self.tokens))

    def check(self, token):
        for kind, value in self.tokens.items():
            if same(token or "", value):
                return kind
        return None


class Pairing:
    """A short PIN the installed app trades for the key (typing a 22-character
    key on an iPad is no fun). A PIN exists only after the owner's screen asks
    for one, works once, and is dropped after a few wrong tries; wrong tries
    across all PINs are capped per day, then only the QR code pairs."""

    def __init__(self):
        self.lock = threading.Lock()
        self.pin = ""
        self.expires = 0.0
        self.tries = 0
        self.last_try = 0.0
        self.fails: list[float] = []  # when wrong PINs were tried (the last day's)

    def _locked(self, now):
        self.fails = [t for t in self.fails if now - t < 86400]
        return len(self.fails) >= PIN_FAILS_PER_DAY

    def locked(self):
        with self.lock:
            return self._locked(time.monotonic())

    def current(self):
        """The PIN to show ("" while locked) and its seconds left."""
        with self.lock:
            now = time.monotonic()
            if self._locked(now):
                self._drop()
                return "", 0
            if now >= self.expires:
                self.pin = f"{secrets.randbelow(1_000_000):06d}"
                self.expires = now + PIN_TTL
                self.tries = 0
            return self.pin, int(self.expires - now)

    def _drop(self):
        self.pin, self.expires, self.tries = "", 0.0, 0

    def check(self, pin):
        with self.lock:
            now = time.monotonic()
            if now - self.last_try < 1:  # one try per second, for everyone
                return False
            self.last_try = now
            if self._locked(now) or not self.pin or now >= self.expires or not isinstance(pin, str):
                return False
            ok = same(pin.strip(), self.pin)
            if not ok:
                self.fails.append(now)
                self.tries += 1
            if ok or self.tries >= PIN_TRIES:
                self._drop()  # the owner's screen shows a new one
            return ok


# --------------------------------------------------------------------------- HTTP

SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "X-Frame-Options": "DENY",
}


class Handler(BaseHTTPRequestHandler):
    server_version = "openpad"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    timeout = HTTP_TIMEOUT

    def log_message(self, fmt, *args):
        if os.environ.get("OPENPAD_DEBUG"):
            # Never log query strings: they carry keys.
            sys.stderr.write(f"{self.client_address[0]} {self.command} {urlparse(self.path).path}\n")

    @property
    def app(self) -> "OpenPadServer":
        return self.server  # type: ignore[return-value]

    # ------------------------------------------------------------- checks

    def _host(self):
        return self.headers.get("Host", "").strip().lower()

    def _host_ok(self):
        return self._host() in self.app.allowed_hosts()

    def _via_tunnel(self):
        t = self.app.tunnel.host
        return bool(t) and self._host() == t

    def _origin(self):
        o = self.headers.get("Origin")
        return o.strip().lower() if o is not None else None

    def _origin_ok(self, owner):
        """Browsers must come from this server, or (owner key only) the installed app."""
        origin = self._origin()
        if origin is None:
            return True  # not a browser (curl, the CLI); a key is still required
        if origin == APP_ORIGIN:
            return owner
        own = {f"{s}://{h}" for h in self.app.allowed_hosts() for s in ("http", "https")}
        if self.app.tunnel.host:
            own.add(f"https://{self.app.tunnel.host}")
        return origin in own

    def _key_ok(self, q, header_only=False):
        if self._via_tunnel():
            return False  # the owner key is never accepted from the internet
        cand = self.headers.get("X-OpenPad-Key", "")
        if not cand and not header_only:
            cand = (q.get("k") or [""])[0]
        return same(cand, self.app.token)

    def _guest(self, q):
        return self.app.guests.check((q.get("g") or [""])[0])

    # ------------------------------------------------------------- responses

    def _cors(self):
        if self._origin() == APP_ORIGIN:
            return {"Access-Control-Allow-Origin": APP_ORIGIN, "Vary": "Origin"}
        return {}

    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        headers = {"Cache-Control": "no-store", **SECURITY_HEADERS, **self._cors(), **(extra or {})}
        for k, v in headers.items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj, separators=(",", ":")).encode(), "application/json")

    def _deny(self, code=403, msg="forbidden"):
        self._json({"error": msg}, code)

    def _page(self, name):
        host = self._host()
        csp = ("default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; "
               "font-src 'self' data: blob:; worker-src 'self' blob:; manifest-src 'self'; "
               f"connect-src 'self' ws://{host} wss://{host}; base-uri 'none'; form-action 'none'; "
               "frame-ancestors 'none'")
        body = (WEB_DIR / name).read_bytes()
        if name == "app.html":
            # The web manifest is for the installed copy on GitHub Pages. Without
            # it, "Add to Home Screen" here keeps the page's own address (and key).
            body = body.replace(b'<link rel="manifest" href="manifest.webmanifest">\n', b"")
        self._send(200, body, "text/html; charset=utf-8", {"Content-Security-Policy": csp})

    # ------------------------------------------------------------- routing

    def handle_one_request(self):
        super().handle_one_request()
        if not self.app.trusted():
            self.close_connection = True  # no keep-alive before an owner key or guest link

    def do_HEAD(self):
        self.do_GET()

    def do_OPTIONS(self):
        """CORS preflight for the installed app."""
        if not self._host_ok() or self._origin() != APP_ORIGIN or self._via_tunnel():
            return self._deny()
        self.send_response(204)
        for k, v in {"Access-Control-Allow-Origin": APP_ORIGIN, "Vary": "Origin",
                     "Access-Control-Allow-Methods": "GET, POST, PUT",
                     "Access-Control-Allow-Headers": "X-OpenPad-Key, X-OpenPad-Digest, Content-Type",
                     "Access-Control-Allow-Private-Network": "true",
                     "Access-Control-Max-Age": "600", "Content-Length": "0", **SECURITY_HEADERS}.items():
            self.send_header(k, v)
        self.end_headers()

    def _tunnel_ok(self, path):
        """From the internet, only what a guest needs."""
        return path in GUEST_PATHS or path in STATIC or re.fullmatch(r"/api/asset/[0-9a-f]{64}", path)

    def do_GET(self):
        if not self._host_ok():
            return self._deny(421, "unknown host")
        url = urlparse(self.path)
        q = parse_qs(url.query)
        path = url.path
        if self._via_tunnel() and not self._tunnel_ok(path):
            return self._deny(404, "not found")

        if path == "/api/ping":
            info = {"app": "openpad", "version": __version__}
            # Prove we hold the key, so the CLI never hands it to some other
            # program that took the port (see cli.probe).
            nonce = (q.get("n") or [""])[0]
            if re.fullmatch(r"[0-9a-f]{16,64}", nonce) and not self._via_tunnel():
                info["proof"] = ping_proof(self.app.token, nonce)
            return self._json(info)
        if path in PAGES:
            return self._page(PAGES[path])
        if path in STATIC:
            f, ctype = STATIC[path]
            return self._send(200, f.read_bytes(), ctype, {"Cache-Control": "no-cache"})

        owner = self._key_ok(q)
        guest = None if owner else self._guest(q)
        if not owner and not guest:
            return self._deny()
        if not self._origin_ok(owner):
            return self._deny()
        self.app.trust(owner)

        if path == "/ws":
            return self._websocket(q, owner, guest)
        if path == "/theme.css":
            return self._send(200, self.app.theme.css().encode(), "text/css; charset=utf-8")
        if path == "/api/live/frame.jpg":
            frame = self.app.hub.frame
            return self._send(200, frame, "image/jpeg") if frame else self._deny(404, "no live window")
        m = re.fullmatch(r"/api/asset/([0-9a-f]{64})", path)
        if m:
            if not owner and m.group(1) not in self.app.hub.guest_assets():
                return self._deny(404, "not found")
            return self._asset(m.group(1))
        if not owner:
            return self._deny()

        if path == "/api/info":
            return self._json(self.app.info())
        if path == "/api/qr.svg":
            which = (q.get("for") or ["app"])[0]
            url = self.app.link(which)
            return self._send(200, qr.svg(url, border=1).encode(), "image/svg+xml") if url else self._deny(404, "no link")
        if path == "/api/pairing":
            pin, left = self.app.pairing.current()
            return self._json({"pin": pin, "expires": left, "locked": not pin, "addresses": self.app.addresses(), "name": socket.gethostname(),
                               "fingerprint": self.app.ca.fingerprint(), "app": APP_URL})
        if path == "/api/ca.crt":
            return self._send(200, self.app.ca.ca_der, "application/x-x509-ca-cert",
                              {"Content-Disposition": 'attachment; filename="OpenPad.crt"'})
        if path == "/api/sync":
            with self.app.hub.lock:
                return self._json({"notebooks": self.app.store.summaries(), "deleted": self.app.store.deleted,
                                   "live": self.app.hub.nb["id"], "pdfs": self.app.store.mirror.pdf_digests(),
                                   "syncFolder": str(self.app.store.notes)})
        m = re.fullmatch(r"/api/sync/nb/([A-Za-z0-9_-]{1,40})", path)
        if m:
            with self.app.hub.lock:
                nb = self.app.store.get(m.group(1))
                body = json.dumps(nb, separators=(",", ":")).encode() if nb else None
            return self._send(200, body, "application/json") if body else self._deny(404, "not found")
        self._deny(404, "not found")

    def do_POST(self):
        if not self._host_ok():
            return self._deny(421, "unknown host")
        url = urlparse(self.path)
        q = parse_qs(url.query)
        path = url.path
        if self._via_tunnel():
            return self._deny(404, "not found")

        if path == "/api/redeem":
            # One-time launch code -> key. Lets the CLI open the share window
            # without putting the long-lived key on a process command line.
            if not self._origin_ok(False):
                return self._deny()
            body = self._read_small_body()
            key = self.app.redeem(body.get("c") if isinstance(body, dict) else None)
            return self._json({"k": key}) if key else self._deny()
        if path == "/api/pair":
            if not self._origin_ok(True):
                return self._deny()
            body = self._read_small_body()
            if self.app.pairing.locked():
                return self._deny(429, "too many wrong PINs today; pair with the QR code instead")
            if not self.app.pairing.check(body.get("pin") if isinstance(body, dict) else None):
                return self._deny(403, "wrong or expired PIN")
            return self._json({"k": self.app.token, "name": socket.gethostname()})

        # The CLI's control endpoints accept the key only as a header.
        header_only = path in ("/api/launch", "/api/shutdown")
        if not self._key_ok(q, header_only) or not self._origin_ok(True):
            return self._deny()
        self.app.trust(owner=True)
        if path == "/api/launch":
            return self._json({"c": self.app.new_launch_code()})
        if path == "/api/shutdown":
            self._json({"ok": True})
            threading.Thread(target=self.app.shutdown, daemon=True).start()
            return
        if path == "/api/live":
            body = self._read_small_body()
            action = body.get("action") if isinstance(body, dict) else None
            if action == "start":
                self.app.hub.live_start()
            elif action == "stop":
                self.app.hub.live_stop()
            else:
                return self._deny(400, "action must be start or stop")
            return self._json({"ok": True, "live": self.app.hub.live})
        if path == "/api/guests":
            body = self._read_small_body() or {}
            action = body.get("action") if isinstance(body, dict) else None
            if action == "rotate":
                self.app.guests.rotate()
                self.app.hub.kick_guests()
            elif action == "internet-on":
                self.app.tunnel.start()
            elif action == "internet-off":
                self.app.tunnel.stop()
            return self._json(self.app.info())
        if path == "/api/sync/nb":
            return self._sync_notebook()
        if path == "/api/sync/request":
            pads = self.app.hub.request_sync()
            return self._json({"pads": pads, "syncFolder": str(self.app.store.notes), "lastSync": self.app.last_sync})
        if path == "/api/settings":
            body = self._read_small_body()
            if not isinstance(body, dict):
                return self._deny(400, "expected settings")
            if "syncFolder" in body:
                try:
                    with self.app.hub.lock:
                        self.app.store.set_sync_folder(body["syncFolder"])
                except (ValueError, OSError) as e:
                    return self._json({"error": f"Can't use that folder: {e}"}, 400)
                self.app.mark_status()
            return self._json(self.app.info())
        if path == "/api/sync/delete":
            body = self._read_small_body()
            nid = N.clean_id(body.get("id")) if isinstance(body, dict) else None
            if not nid:
                return self._deny(400, "bad id")
            with self.app.hub.lock:
                self.app.store.delete(nid, N.stamp(body.get("t")) or N.now_ms())
            self.app.hub.notebook_deleted(nid)
            return self._json({"ok": True})
        self._deny(404, "not found")

    def do_PUT(self):
        if not self._host_ok():
            return self._deny(421, "unknown host")
        url = urlparse(self.path)
        q = parse_qs(url.query)
        if self._via_tunnel() or not self._key_ok(q) or not self._origin_ok(True):
            return self._deny()
        self.app.trust(owner=True)
        size = self._length()
        m = re.fullmatch(r"/api/asset/([0-9a-f]{64})", url.path)
        if m:
            if self.app.store.has_asset(m.group(1)):
                self._drain(size)
                return self._json({"ok": True})
            try:
                self.app.store.save_asset(self.rfile, size, m.group(1))
            except (ValueError, OSError) as e:
                self.close_connection = True
                return self._json({"error": str(e)}, 400)
            return self._json({"ok": True})
        m = re.fullmatch(r"/api/sync/pdf/([A-Za-z0-9_-]{1,40})/([A-Za-z0-9_-]{1,40})", url.path)
        if m:
            if not 0 < size <= MAX_SECTION_PDF:
                self.close_connection = True
                return self._deny(413, "too large")
            data = self._read_exact(size)
            if data is None:
                return
            try:
                with self.app.hub.lock:
                    out = self.app.store.write_section_pdf(m.group(1), m.group(2), data,
                                                           (self.headers.get("X-OpenPad-Digest") or "").strip())
            except (ValueError, OSError) as e:
                return self._json({"error": str(e)}, 400)
            return self._json({"ok": True, "file": str(out)})
        self._deny(404, "not found")

    # ------------------------------------------------------------- bodies

    def _length(self):
        try:
            return int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return -1

    def _read_exact(self, n):
        chunks, left = [], n
        while left:
            chunk = self.rfile.read(min(left, 1 << 20))
            if not chunk:
                self.close_connection = True
                return None
            chunks.append(chunk)
            left -= len(chunk)
        return b"".join(chunks)

    def _drain(self, n):
        while n > 0:
            chunk = self.rfile.read(min(n, 1 << 20))
            if not chunk:
                break
            n -= len(chunk)

    def _read_small_body(self):
        n = self._length()
        if not 0 < n <= 4096:
            return None
        try:
            return json.loads(self.rfile.read(n))
        except ValueError:
            return None

    def _sync_notebook(self):
        """The notes app sends its copy of a notebook; the merged result comes back."""
        n = self._length()
        if not 0 < n <= MAX_NOTEBOOK_BYTES:
            self.close_connection = True
            return self._deny(413, "notebook too large")
        raw = self._read_exact(n)
        if raw is None:
            return
        try:
            nb = N.clean_notebook(json.loads(raw))
        except (ValueError, RecursionError):
            nb = None
        if not nb:
            return self._deny(400, "not a notebook")
        theirs = (self.headers.get("X-OpenPad-Digest") or "").strip()
        with self.app.hub.lock:
            if nb["id"] in self.app.store.deleted:
                return self._json({"deleted": self.app.store.deleted[nb["id"]]})
            try:
                merged = self.app.store.put(nb)
            except ValueError as e:
                return self._json({"error": str(e)}, 400)
            d = N.digest(merged)
            missing = sorted(a for a in N.assets(merged) if not self.app.store.has_asset(a))
            body = json.dumps({"d": d, "missing": missing, "nb": merged if d != theirs else None},
                              separators=(",", ":")).encode()
            # Still under the lock, so no state is sent from the merged notebook
            # before the parts that describe it are refreshed.
            self.app.hub.notebook_changed(nb["id"])
        self._send(200, body, "application/json")

    def _asset(self, sha):
        f = self.app.store.asset_path(sha)
        if not f or not f.exists():
            return self._deny(404, "not found")
        size = f.stat().st_size
        with open(f, "rb") as fh:
            head = fh.read(8)
        ctype = "application/pdf" if head.startswith(b"%PDF") else \
            "image/jpeg" if head.startswith(b"\xff\xd8\xff") else \
            "image/png" if head.startswith(b"\x89PNG") else "application/octet-stream"
        extra = {"Cache-Control": "private, max-age=31536000, immutable", "Accept-Ranges": "bytes"}
        # Range requests let pdf.js fetch only the parts of a big PDF it needs.
        start, length, code = 0, size, 200
        m = re.fullmatch(r"bytes=(\d*)-(\d*)", (self.headers.get("Range") or "").strip())
        if m and (m.group(1) or m.group(2)):
            if m.group(1):
                start = int(m.group(1))
                end = min(int(m.group(2)) if m.group(2) else size - 1, size - 1)
            else:
                start, end = max(0, size - int(m.group(2))), size - 1
            if start > end or start >= size:
                return self._send(416, b"", extra={"Content-Range": f"bytes */{size}"})
            length, code = end - start + 1, 206
            extra["Content-Range"] = f"bytes {start}-{end}/{size}"
        self.send_response(code)
        for k, v in {"Content-Type": ctype, "Content-Length": str(length), **SECURITY_HEADERS, **self._cors(), **extra}.items():
            self.send_header(k, v)
        self.end_headers()
        if self.command == "HEAD":
            return
        # Streamed in 1 MiB pieces: a request never holds more than that in memory.
        with open(f, "rb") as fh:
            fh.seek(start)
            while length > 0:
                chunk = fh.read(min(length, 1 << 20))
                if not chunk:
                    break
                self.wfile.write(chunk)
                length -= len(chunk)

    def _websocket(self, q, owner, guest):
        key = self.headers.get("Sec-WebSocket-Key")
        if not key or "websocket" not in self.headers.get("Upgrade", "").lower():
            return self._deny(400, "expected websocket")
        legacy = (q.get("v") or [""])[0] != str(PROTOCOL)
        if owner:
            role, write, by = ("pad" if (q.get("role") or [""])[0] == "pad" else "view"), True, None
        else:
            me = (q.get("me") or [""])[0]
            if not GUEST_SECRET_RE.fullmatch(me):
                me = secrets.token_urlsafe(16)  # no usable secret: a new identity for this connection
            role, write, by = "guest", guest == "w", guest_tag(self.app.token, me)
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(HTTPStatus.SWITCHING_PROTOCOLS)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        try:
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass  # a socketpair behind the TLS layer
        self.connection.settimeout(WS_TIMEOUT)  # server pings keep live peers inside this
        if legacy:
            # A page from an older version (still open in a tab): it shows this
            # as a notice, then keeps reconnecting and showing it until reloaded.
            note = {"t": "live", "state": "error", "error": "OpenPad was updated. Reload this page to get the new version."}
            try:
                self.connection.sendall(WSConn._frame(0x1, json.dumps(note).encode()) + WSConn._frame(0x8, b""))
            except OSError:
                pass
            return
        conn = WSConn(self.connection, self.rfile, role, write, by)
        hub = self.app.hub
        if not hub.join(conn):
            conn.close()
            return
        try:
            while conn.alive:
                raw = conn.recv()
                if raw is None:
                    break
                if isinstance(raw, bytes):
                    hub.handle_frame(conn, raw)
                    continue
                try:
                    msg = json.loads(raw)
                except (ValueError, RecursionError):
                    continue
                if isinstance(msg, dict):
                    hub.handle(conn, msg)
        except (ConnectionError, OSError):
            pass
        finally:
            hub.leave(conn)


# --------------------------------------------------------------------------- Network helpers

SKIP_IFACES = re.compile(r"^(lo|tun|tap|wg|proton|tailscale|docker|br-|veth|virbr|utun|llw|awdl|bridge|zt|anpi|ap\d)")
# Windows interface aliases (e.g. "Wi-Fi", "Ethernet", "ProtonVPN", "vEthernet (WSL)").
SKIP_WINDOWS_IFACES = re.compile(r"vpn|tap|tun|wireguard|tailscale|zerotier|vethernet|virtualbox|vmware|"
                                 r"hyper-v|wsl|loopback|bluetooth|npcap", re.I)
_lan_cache = (0.0, [])
NO_WINDOW = {"creationflags": 0x08000000} if WINDOWS else {}  # CREATE_NO_WINDOW


def _windows_interfaces():
    """(alias, IPv4) pairs from PowerShell; falls back to the host's addresses."""
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
                              "Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias,IPAddress "
                              "| ConvertTo-Json -Compress"],
                             capture_output=True, text=True, timeout=8, **NO_WINDOW).stdout
        rows = json.loads(out or "[]")
        rows = rows if isinstance(rows, list) else [rows]
        return [("~" if SKIP_WINDOWS_IFACES.search(r.get("InterfaceAlias") or "") else "", r.get("IPAddress", ""))
                for r in rows if isinstance(r, dict)]
    except (OSError, ValueError, subprocess.SubprocessError):
        try:
            return [("", ai[4][0]) for ai in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)]
        except OSError:
            return []


def lan_addresses():
    """Private IPv4 addresses of physical-looking interfaces, best first (cached 15 s)."""
    global _lan_cache
    if time.monotonic() - _lan_cache[0] < 15:
        return list(_lan_cache[1])
    result = _lan_addresses()
    _lan_cache = (time.monotonic(), result)
    return list(result)


def _posix_interfaces():
    """(interface, IPv4) pairs from `ip` (Linux) or `ifconfig` (macOS/BSD)."""
    found = []
    if sys.platform != "darwin":  # macOS: some `ip` wrappers are slow; ifconfig is native
        try:
            out = subprocess.run(["ip", "-j", "-4", "addr"], capture_output=True, text=True, timeout=5)
            for iface in json.loads(out.stdout or "[]"):
                for a in iface.get("addr_info", []):
                    found.append((iface.get("ifname", ""), a.get("local", "")))
            return found
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    try:
        out = subprocess.run(["ifconfig"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return found
    name = ""
    for line in out.splitlines():
        if line and not line[0].isspace():
            name = line.split(":")[0]
        m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", line)
        if m:
            found.append((name, m.group(1)))
    return found


def _lan_addresses():
    if WINDOWS:
        # "~" marks VPN/virtual adapters; mapping it to "tun" lets SKIP_IFACES drop it.
        found = [("tun" if alias == "~" else "wi-fi", ip) for alias, ip in _windows_interfaces()]
    else:
        found = _posix_interfaces()

    def private(ip):
        try:
            a = ipaddress.ip_address(ip)
        except ValueError:
            return False
        return a.version == 4 and a.is_private and not a.is_loopback and not a.is_link_local

    good = [(n, ip) for n, ip in found if private(ip) and not SKIP_IFACES.match(n)]
    good.sort(key=lambda x: (not x[1].startswith("192.168."), not re.match(r"^(wl|en|eth|wi-fi)", x[0])))
    return list(dict.fromkeys(ip for _, ip in good))


def local_hostname():
    """This computer's mDNS name (e.g. omarchy.local), which survives address changes."""
    name = socket.gethostname().split(".")[0].lower()
    return f"{name}.local" if re.fullmatch(r"[a-z0-9-]{1,63}", name) else None


def qr_matrix(text):
    """QR code as rows of '0'/'1' (quiet zone included), for the bar plugin.

    Made in-process (openpad/qr.py): the link contains the key, and another
    program's command line would be visible to every user on the machine."""
    try:
        return qr.matrix(text, border=2)
    except ValueError:
        return []


class OpenPadServer(ThreadingHTTPServer):
    daemon_threads = True
    # On Windows SO_REUSEADDR would let another program bind the same port and
    # take over connections; bind exclusively there instead.
    allow_reuse_address = not WINDOWS
    request_queue_size = 32

    def __init__(self, host, port, public_host=None, notes=None):
        from .tls import LocalCA
        from .tunnel import Tunnel

        self.data = data_dir()
        self.port = port
        self.public_host = public_host
        self.token = load_token(self.data)
        self.theme = Theme()
        self._active = 0
        self._active_lock = threading.Lock()
        self._per_address: dict[str, int] = {}  # address -> its connections without the owner key
        # id(connection's socket) -> (deadline, a duplicate of it): the duplicate
        # still reaches the connection after TLS takes over (and detaches) the original.
        self._deadlines: dict[int, tuple[float, socket.socket]] = {}
        self._conn = threading.local()  # this thread's connection (one thread per connection)
        self._codes: dict[str, float] = {}
        self._lan = lan_addresses()  # once before listening; then every 15 s in the background
        self._mdns = local_hostname()
        self._status_dirty = True
        self.store = Store(self.data, notes)
        self.hub = Hub(self.store, self.data, on_change=self._mark_status)
        self.hub.on_sync = self._synced
        try:
            self.last_sync = json.loads((self.data / "last-sync.json").read_text())
        except (OSError, ValueError):
            self.last_sync = None
        self._mirror_now = False
        self.guests = Guests(self.data)
        self.pairing = Pairing()
        self.tunnel = Tunnel(port, self._mark_status)
        self.ca = LocalCA(self.data / "tls", write_private)
        self.tls = self.ca.ensure(self.tls_names())
        super().__init__((host, port), Handler)
        threading.Thread(target=self._maintenance, daemon=True).start()
        threading.Thread(target=self._watchdog, daemon=True).start()

    def server_bind(self):
        if WINDOWS:
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()

    # Cap concurrent connections so idle sockets can't exhaust threads, and
    # each address's (owner key aside) so one device can't take them all.
    def process_request(self, request, client_address):
        addr = client_address[0]
        counted = not _loopback(addr)
        try:
            watch = request.dup()
        except OSError:
            self.shutdown_request(request)
            return
        with self._active_lock:
            if self._active >= MAX_HTTP_CONNECTIONS or \
                    (counted and self._per_address.get(addr, 0) >= MAX_CONNECTIONS_PER_ADDRESS):
                refused = True
            else:
                refused = False
                self._active += 1
                if counted:
                    self._per_address[addr] = self._per_address.get(addr, 0) + 1
                self._deadlines[id(request)] = (time.monotonic() + UNTRUSTED_DEADLINE, watch)
        if refused:
            watch.close()
            self.shutdown_request(request)
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        c = self._conn
        c.key, c.addr = id(request), client_address[0]
        c.armed, c.counted = True, not _loopback(c.addr)
        try:
            super().process_request_thread(request, client_address)
        finally:
            with self._active_lock:
                self._active -= 1
                self._release(c, uncount=True)

    def _release(self, c, uncount):
        """Lift this connection's deadline and, with `uncount`, take it out of
        its address's count (caller holds _active_lock)."""
        if c.armed:
            c.armed = False
            entry = self._deadlines.pop(c.key, None)
            if entry:
                entry[1].close()
        if uncount and c.counted:
            c.counted = False
            left = self._per_address.get(c.addr, 1) - 1
            if left > 0:
                self._per_address[c.addr] = left
            else:
                self._per_address.pop(c.addr, None)

    def trust(self, owner):
        """The request on this thread's connection showed the owner key or a
        guest link: it may stay open and take its time. Guest connections still
        count toward their address's limit."""
        c = self._conn
        if hasattr(c, "armed"):
            with self._active_lock:
                self._release(c, uncount=owner)

    def trusted(self):
        return not getattr(self._conn, "armed", False)

    def _watchdog(self):
        """Close untrusted connections that run past their deadline (a request
        trickled in a byte at a time, or a TLS handshake that never finishes)."""
        while True:
            time.sleep(0.5)
            now = time.monotonic()
            with self._active_lock:
                late = [k for k, (deadline, _) in self._deadlines.items() if deadline <= now]
                late = [self._deadlines.pop(k)[1] for k in late]
            for sock in late:
                try:
                    sock.shutdown(socket.SHUT_RDWR)  # the handler's next read or write fails, and it ends
                except OSError:
                    pass
                sock.close()

    def finish_request(self, request, client_address):
        """HTTP and HTTPS share the port: a TLS handshake starts with 0x16."""
        try:
            request.settimeout(HTTP_TIMEOUT)
            first = request.recv(1, socket.MSG_PEEK)
        except OSError:
            return
        if first != b"\x16":
            return super().finish_request(request, client_address)
        from .tls import pump

        try:
            tls_sock = self.tls.wrap_socket(request, server_side=True)
        except (OSError, ValueError):
            return
        inner, outer = socket.socketpair()
        threading.Thread(target=pump, args=(tls_sock, outer, WS_TIMEOUT + 10), daemon=True).start()
        try:
            self.RequestHandlerClass(inner, client_address, self)
        finally:
            try:
                inner.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            inner.close()

    def handle_error(self, request, client_address):
        # Clients vanishing mid-request (sleeping iPads, closed tabs) is normal.
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionError, TimeoutError, socket.timeout)):
            return
        sys.stderr.write(f"openpad: request error: {exc!r}\n")

    def allowed_hosts(self) -> set[str]:
        """Names this server answers to. Never runs a command: requests must not
        wait on network enumeration (the LAN list is refreshed in the background)."""
        names = ["127.0.0.1", "localhost", "[::1]", *self._lan]
        if self._mdns:
            names.append(self._mdns)
        if self.public_host:
            names.append(self.public_host)
        hosts = {f"{n}:{self.port}".lower() for n in names}
        if self.tunnel.host:
            hosts.add(self.tunnel.host)
        return hosts

    def tls_names(self):
        return ["127.0.0.1", "localhost", *self._lan, *([self._mdns] if self._mdns else []),
                *([self.public_host] if self.public_host else [])]

    def refresh_lan(self):
        self._lan = lan_addresses()
        self.tls = self.ca.ensure(self.tls_names())

    def addresses(self):
        hosts = [self.public_host] if self.public_host else self._lan
        return [f"{h}:{self.port}" for h in hosts] + ([f"{self._mdns}:{self.port}"] if self._mdns else [])

    def link(self, which):
        hosts = [self.public_host] if self.public_host else self._lan
        if which == "app":
            return f"http://{hosts[0]}:{self.port}/app?k={self.token}" if hosts else None
        if which == "setup":
            return f"http://{hosts[0]}:{self.port}/setup?k={self.token}" if hosts else None
        if which in ("w", "v"):
            return f"http://{hosts[0]}:{self.port}/join#{which}={self.guests.tokens[which]}" if hosts else None
        if which in ("iw", "iv") and self.tunnel.url:
            return f"{self.tunnel.url}/join#{which[1]}={self.guests.tokens[which[1]]}"
        return None

    def pad_urls(self):
        hosts = [self.public_host] if self.public_host else self._lan
        return [f"http://{h}:{self.port}/app?k={self.token}" for h in hosts]

    def info(self):
        return {"urls": self.pad_urls(), "version": __version__, "setup": self.link("setup"), "app": APP_URL,
                "guests": {"w": self.link("w"), "v": self.link("v"), "iw": self.link("iw"), "iv": self.link("iv"),
                           "count": self.hub.peers()["guests"], "internet": self.tunnel.info()},
                "notes": str(self.store.notes), "syncFolder": str(self.store.notes), "lastSync": self.last_sync}

    # one-time launch codes for opening the share window
    def new_launch_code(self):
        code = secrets.token_urlsafe(16)
        with self._active_lock:
            self._codes[code] = time.monotonic() + LAUNCH_CODE_TTL
        return code

    def redeem(self, code):
        if not isinstance(code, str):
            return None
        with self._active_lock:
            expires = self._codes.pop(code, None)
        try:
            launcher_path(code).unlink(missing_ok=True)
        except OSError:  # Windows: the browser may still have it open; expiry cleans it up
            pass
        return self.token if expires and expires > time.monotonic() else None

    def _synced(self, report):
        self.last_sync = report
        write_private(self.data / "last-sync.json", json.dumps(report))
        self._mirror_now = True  # bring the copy fully up to date right away
        self._status_dirty = True

    # status file for the Omarchy bar plugin
    def _mark_status(self):
        self._status_dirty = True

    def mark_status(self):
        self._status_dirty = True

    def write_status(self, running=True):
        peers = self.hub.peers()
        url = (self.pad_urls() or [""])[0]
        with self.hub.lock:
            order = N.order(self.hub.nb)
            page = order.index(self.hub.page) if self.hub.page in order else 0
            title = "" if self.hub.placeholder else self.hub.nb["title"]
        status = {"app": "openpad", "version": __version__, "running": running, "pid": os.getpid(),
                  "port": self.port, "url": url, "qr": qr_matrix(url) if url and running else [],
                  "pads": peers["pads"] if running else 0, "views": peers["views"] if running else 0,
                  "guests": peers["guests"] if running else 0, "notebook": title,
                  "page": page, "pages": len(order), "live": self.hub.live["state"] if running else "idle",
                  "internet": self.tunnel.url if running else None,
                  "syncFolder": str(self.store.notes), "lastSync": self.last_sync,
                  "guest_link": self.link("w") if running else None,
                  "updated": int(time.time())}
        try:
            write_private(runtime_dir() / "status.json", json.dumps(status))
        except OSError:
            pass

    def save(self):
        with self.hub.lock:
            items = self.store.flush()
        self.store.write_out(items)

    def update_mirror(self, force=False):
        with self.hub.lock:
            items = self.store.mirror_items(force=force)
        self.store.write_mirror(items)

    def _maintenance(self):
        tick = 0
        last_url = None
        while True:
            time.sleep(1)
            tick += 1
            try:
                if tick % 2 == 0:
                    self.save()
                if tick % 3 == 0 or self._mirror_now:
                    force, self._mirror_now = self._mirror_now, False
                    self.update_mirror(force)
                    if self.theme.changed():
                        self.hub.broadcast({"t": "theme", "v": self.theme.version})
                if tick % WS_PING_EVERY == 0:
                    self.hub.ping_all()
                if tick % 15 == 0:
                    self.refresh_lan()
                if tick % 3600 == 30:
                    with self.hub.lock:
                        self.store.gc_assets()
                if tick % 10 == 0:
                    url = (self.pad_urls() or [""])[0]
                    if url != last_url:
                        last_url = url
                        self._status_dirty = True
                    with self._active_lock:
                        now = time.monotonic()
                        expired = [c for c, e in self._codes.items() if e <= now]
                        self._codes = {c: e for c, e in self._codes.items() if e > now}
                    for c in expired:
                        try:
                            launcher_path(c).unlink(missing_ok=True)
                        except OSError:
                            pass
                if self._status_dirty or tick % 10 == 0:
                    self._status_dirty = False
                    self.write_status()
            except Exception as e:  # keep the server alive; report and carry on
                sys.stderr.write(f"openpad: maintenance error: {e}\n")

    def server_close(self):
        self.hub.live_stop(wait=3)
        self.tunnel.stop()
        try:
            self.save()
            self.update_mirror(force=True)
            self.write_status(running=False)
        finally:
            super().server_close()
