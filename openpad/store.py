"""Notebooks on the computer's disk.

  <data dir>/notebooks/<id>.json     notebook (strokes, layout), owner-only
  <data dir>/assets/<sha256>         PDFs and images pages show, by content hash
  <data dir>/notebooks/deleted.json  deleted notebooks, so sync doesn't bring them back
  ~/Documents/OpenPad/<Notebook>/<Section>.pdf
                                     readable copies the iPad renders while syncing

Callers hold the server's lock; nothing here locks on its own.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
from pathlib import Path

from . import notebook as N

MAX_ASSET_BYTES = 200 * 1024 * 1024
MAX_NOTEBOOKS = 1000
WINDOWS = os.name == "nt"


def write_private(path: Path, data: str | bytes):
    """Atomically write a file only the owner can read."""
    tmp = path.with_name(f".{path.name}.{secrets.token_hex(4)}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data.encode() if isinstance(data, str) else data)
    os.replace(tmp, path)


def private_dir(d: Path) -> Path:
    """A directory only this user can read. On Windows the per-user profile
    folders are already private to the user."""
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not WINDOWS:
        os.chmod(d, 0o700)
    return d


def documents_dir() -> Path:
    if WINDOWS:
        try:  # Documents may be redirected (OneDrive); ask the shell where it is
            import ctypes
            from ctypes import wintypes

            class GUID(ctypes.Structure):
                _fields_ = [("a", wintypes.DWORD), ("b", wintypes.WORD), ("c", wintypes.WORD), ("d", ctypes.c_ubyte * 8)]

            fid = GUID(0xFDD39AD0, 0x238F, 0x46AF, (ctypes.c_ubyte * 8)(0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7))
            out = ctypes.c_wchar_p()
            if ctypes.windll.shell32.SHGetKnownFolderPath(ctypes.byref(fid), 0, None, ctypes.byref(out)) == 0:
                path = out.value
                ctypes.windll.ole32.CoTaskMemFree(out)
                return Path(path)
        except (OSError, AttributeError, ValueError):
            pass
        return Path(os.path.expanduser("~/Documents"))
    if sys.platform.startswith("linux") and shutil.which("xdg-user-dir"):
        try:
            out = subprocess.run(["xdg-user-dir", "DOCUMENTS"], capture_output=True, text=True, timeout=3).stdout.strip()
            if out and out != os.path.expanduser("~") and os.path.isabs(out):
                return Path(out)
        except (OSError, subprocess.SubprocessError):
            pass
    return Path(os.path.expanduser("~/Documents"))


def notes_dir() -> Path:
    custom = os.environ.get("OPENPAD_NOTES")
    return Path(os.path.expanduser(custom)) if custom else documents_dir() / "OpenPad"


def safe_name(text, fallback):
    name = re.sub(r'[\x00-\x1f\x7f<>:"/\\|?*]', "", text).strip().strip(".")
    if name.upper() in {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(10)), *(f"LPT{i}" for i in range(10))}:
        name = ""
    return (name or fallback)[:80]


class Store:
    def __init__(self, root: Path, notes: Path | None = None):
        self.root = root
        self.nb_dir = private_dir(root / "notebooks")
        self.asset_dir = private_dir(root / "assets")
        self.notes = notes or notes_dir()
        self.cache: dict[str, dict] = {}
        self.dirty: set[str] = set()
        self.deleted = self._read_json(self.nb_dir / "deleted.json", {})
        self.folders = self._read_json(self.nb_dir / "folders.json", {})  # nb id -> {dir, sections: {id: file}}
        self._summaries: dict[str, dict] = {}

    @staticmethod
    def _read_json(path, default):
        try:
            data = json.loads(path.read_text())
            return data if isinstance(data, type(default)) else default
        except (OSError, ValueError):
            return default

    # ------------------------------------------------------------- notebooks

    def ids(self):
        return sorted({p.stem for p in self.nb_dir.glob("*.json") if N.clean_id(p.stem)} | set(self.cache))

    def get(self, nid):
        if nid in self.cache:
            return self.cache[nid]
        if not N.clean_id(nid) or nid in self.deleted:
            return None
        try:
            nb = N.clean_notebook(json.loads((self.nb_dir / f"{nid}.json").read_text()))
        except (OSError, ValueError, RecursionError):
            return None
        if nb and nb["id"] == nid:
            self.cache[nid] = nb
            return nb
        return None

    def put(self, nb):
        """Merge a copy in and return the merged notebook (the cached object
        itself, so live sessions see it)."""
        if nb["id"] in self.deleted:
            return None
        old = self.get(nb["id"])
        if old is None and len(self.ids()) >= MAX_NOTEBOOKS:
            raise ValueError("too many notebooks")
        merged = N.merge(old, nb) if old else nb
        if old is not None and merged is not old:
            old.clear()
            old.update(merged)  # keep the identity: the live session holds it
            merged = old
        self.cache[nb["id"]] = merged
        self.touch(nb["id"])
        return merged

    def touch(self, nid):
        self.dirty.add(nid)
        self._summaries.pop(nid, None)

    def delete(self, nid, t):
        if not N.clean_id(nid):
            return
        self.deleted[nid] = max(int(t or 0), self.deleted.get(nid, 0))
        self.cache.pop(nid, None)
        self.dirty.discard(nid)
        self._summaries.pop(nid, None)
        trash = private_dir(self.root / "trash")
        src = self.nb_dir / f"{nid}.json"
        if src.exists():  # kept for a while in case the delete was a mistake
            os.replace(src, trash / f"{nid}-{int(time.time())}.json")
        folder = self.folders.pop(nid, None)
        if folder and (self.notes / folder["dir"]).is_dir():
            try:
                os.replace(self.notes / folder["dir"], trash / f"{folder['dir']}-{int(time.time())}")
            except OSError:
                pass
        write_private(self.nb_dir / "deleted.json", json.dumps(self.deleted))
        write_private(self.nb_dir / "folders.json", json.dumps(self.folders))

    def summaries(self):
        out = []
        for nid in self.ids():
            if nid in self.deleted:
                continue
            if nid not in self._summaries:
                nb = self.get(nid)
                if nb:
                    self._summaries[nid] = N.summary(nb)
            if nid in self._summaries:
                out.append(self._summaries[nid])
        return out

    def flush(self):
        """Write changed notebooks. Returns (id, json) pairs to write outside the
        lock with write_out()."""
        out = []
        for nid in sorted(self.dirty):
            nb = self.cache.get(nid)
            if nb:
                out.append((nid, json.dumps(nb, separators=(",", ":"))))
        self.dirty.clear()
        return out

    def write_out(self, items):
        for nid, data in items:
            write_private(self.nb_dir / f"{nid}.json", data)

    # ------------------------------------------------------------- assets

    def asset_path(self, sha):
        return self.asset_dir / sha if N.SHA_RE.match(sha or "") else None

    def has_asset(self, sha):
        p = self.asset_path(sha)
        return bool(p and p.exists())

    def save_asset(self, rfile, size, sha):
        """Stream an upload to disk and keep it only if its hash is `sha`."""
        if not 0 < size <= MAX_ASSET_BYTES:
            raise ValueError(f"files are limited to {MAX_ASSET_BYTES // 1048576} MB")
        final = self.asset_path(sha)
        if final is None:
            raise ValueError("bad hash")
        tmp = self.asset_dir / f".up-{secrets.token_hex(6)}"
        h = hashlib.sha256()
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as f:
                left = size
                while left:
                    chunk = rfile.read(min(left, 1 << 20))
                    if not chunk:
                        raise ValueError("upload interrupted")
                    h.update(chunk)
                    f.write(chunk)
                    left -= len(chunk)
            if h.hexdigest() != sha:
                raise ValueError("the file doesn't match its hash")
            os.replace(tmp, final)
        finally:
            tmp.unlink(missing_ok=True)

    def add_asset_bytes(self, data: bytes) -> str:
        sha = hashlib.sha256(data).hexdigest()
        if not self.has_asset(sha):
            write_private(self.asset_dir / sha, data)
        return sha

    def gc_assets(self, keep_extra=()):
        """Delete files no notebook uses (after a grace period, so an upload
        that's waiting for its notebook isn't lost)."""
        used = set(keep_extra)
        for nid in self.ids():
            nb = self.get(nid)
            if nb:
                used |= N.assets(nb)
        cutoff = time.time() - 24 * 3600
        for f in self.asset_dir.iterdir():
            if N.SHA_RE.match(f.name) and f.name not in used and f.stat().st_mtime < cutoff:
                f.unlink(missing_ok=True)

    # ------------------------------------------------------------- readable PDFs

    def write_section_pdf(self, nid, sid, data: bytes):
        """Save one section as ~/Documents/OpenPad/<Notebook>/<Section>.pdf."""
        nb = self.get(nid)
        sec = next((s for s in nb["layout"]["sections"] if s["id"] == sid), None) if nb else None
        if not sec:
            raise ValueError("unknown section")
        if not data.startswith(b"%PDF-"):
            raise ValueError("not a PDF")
        private_dir(self.notes)
        entry = self.folders.get(nid) or {"dir": "", "sections": {}}
        want = safe_name(nb["title"], "Notebook")
        taken = {f["dir"] for k, f in self.folders.items() if k != nid}
        if want in taken:
            want = f"{want} ({nid[:4]})"
        if entry["dir"] != want:
            if entry["dir"] and (self.notes / entry["dir"]).is_dir() and not (self.notes / want).exists():
                os.replace(self.notes / entry["dir"], self.notes / want)  # notebook was renamed
            entry["dir"] = want
        folder = private_dir(self.notes / want)
        name = safe_name(sec["title"], "Section")
        others = {f for k, f in entry["sections"].items() if k != sid}
        if f"{name}.pdf" in others:
            name = f"{name} ({sid[:4]})"
        old = entry["sections"].get(sid)
        if old and old != f"{name}.pdf":
            (folder / old).unlink(missing_ok=True)  # section was renamed
        entry["sections"][sid] = f"{name}.pdf"
        # Sections that no longer exist: their PDFs go too.
        live = {s["id"] for s in nb["layout"]["sections"]}
        for gone in [k for k in entry["sections"] if k not in live]:
            (folder / entry["sections"].pop(gone)).unlink(missing_ok=True)
        self.folders[nid] = entry
        write_private(folder / f"{name}.pdf", data)
        write_private(self.nb_dir / "folders.json", json.dumps(self.folders))
        return folder / f"{name}.pdf"

    # ------------------------------------------------------------- Inkcast data

    def migrate_legacy(self):
        """Inkcast kept one board (session.json); it becomes a notebook."""
        legacy = self.root / "session.json"
        if not legacy.exists():
            return None
        try:
            doc = json.loads(legacy.read_text())
        except (OSError, ValueError):
            doc = None
        nb = None
        if isinstance(doc, dict) and isinstance(doc.get("pages"), list):
            t = N.now_ms()
            sec = N.new_id()
            pdf_sha = {}
            for f in self.root.glob("pdf-*.pdf"):
                pdf_sha[f.stem[4:]] = self.add_asset_bytes(f.read_bytes())
            pages, order = {}, []
            for raw in doc["pages"][:N.MAX_PAGES]:
                if not isinstance(raw, dict) or not N.clean_id(raw.get("id")):
                    continue
                bg = raw.get("bg") if isinstance(raw.get("bg"), dict) else {}
                new_bg = None
                if bg.get("pdf") in pdf_sha:
                    new_bg = {"pdf": pdf_sha[bg["pdf"]], "n": bg.get("n")}
                elif bg.get("img") or bg.get("live"):
                    img = self.root / f"img-{raw['id']}.jpg"
                    if img.exists():
                        new_bg = {"img": self.add_asset_bytes(img.read_bytes())}
                page = N.clean_page({**raw, "bg": new_bg, "t": t, "sec": sec, "gone": []})
                if page:
                    pages[page["id"]] = page
                    order.append(page["id"])
            if pages:
                title = (doc.get("pdf") or {}).get("name") or "Inkcast board"
                nb = N.finish({"v": 1, "id": N.new_id(), "title": N.clean_text(title, "Inkcast board"),
                               "size": "wide", "metaT": t, "created": t,
                               "layout": {"t": t, "sections": [{"id": sec, "title": "Board", "pages": order}]},
                               "goneP": [], "pages": pages})
                self.put(nb)
                self.write_out(self.flush())
        os.replace(legacy, self.root / "session.json.migrated")
        for f in list(self.root.glob("pdf-*")) + list(self.root.glob("img-*.jpg")):
            shutil.rmtree(f, ignore_errors=True) if f.is_dir() else f.unlink(missing_ok=True)
        return nb["id"] if nb else None
