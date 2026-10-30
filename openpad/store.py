"""Notebooks on the computer's disk.

  <data dir>/notebooks/<id>.json     notebook (strokes, layout), owner-only
  <data dir>/assets/<sha256>         PDFs and images pages show, by content hash
  <data dir>/notebooks/deleted.json  deleted notebooks, so sync doesn't bring them back
  <sync folder>/...                  a browsable copy of everything (see mirror.py);
                                     ~/Documents/OpenPad unless the user chose another

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
from .mirror import Mirror

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


def notes_dir(data: Path | None = None) -> Path:
    """The sync folder: $OPENPAD_NOTES, else the one chosen in settings, else ~/Documents/OpenPad."""
    custom = os.environ.get("OPENPAD_NOTES")
    if custom:
        return Path(os.path.expanduser(custom))
    if data is not None:
        try:
            chosen = json.loads((data / "config.json").read_text()).get("syncFolder")
            if isinstance(chosen, str) and os.path.isabs(os.path.expanduser(chosen)):
                return Path(os.path.expanduser(chosen))
        except (OSError, ValueError, AttributeError):
            pass
    return documents_dir() / "OpenPad"


def check_sync_folder(value, data: Path) -> Path:
    """A folder the user may pick for the copy (raises ValueError if not)."""
    if not isinstance(value, str) or not value.strip() or len(value) > 1024 or "\x00" in value:
        raise ValueError("choose a folder")
    path = Path(os.path.expanduser(value.strip()))
    if not path.is_absolute():
        raise ValueError("use a full path, e.g. ~/Documents/OpenPad")
    path = Path(os.path.normpath(path))
    home = Path(os.path.expanduser("~"))
    if path in (Path(path.anchor), home) or path == data or data in path.parents or path in data.parents:
        raise ValueError("choose a folder of its own, e.g. ~/Documents/OpenPad")
    if path.exists() and not path.is_dir():
        raise ValueError("that's a file, not a folder")
    path.mkdir(parents=True, exist_ok=True)
    if not os.access(path, os.W_OK):
        raise ValueError("OpenPad can't write to that folder")
    return path


class Store:
    def __init__(self, root: Path, notes: Path | None = None):
        self.root = root
        self.nb_dir = private_dir(root / "notebooks")
        self.asset_dir = private_dir(root / "assets")
        self.mirror = Mirror(self.nb_dir, notes or notes_dir(root), write_private)
        self.cache: dict[str, dict] = {}
        self.dirty: set[str] = set()
        self.mirror_due: dict[str, float] = {}  # nb id -> when it last changed
        self.deleted = self._read_json(self.nb_dir / "deleted.json", {})
        self._summaries: dict[str, dict] = {}

    @property
    def notes(self) -> Path:
        return self.mirror.root

    def set_sync_folder(self, value):
        """Use another sync folder; everything is copied there afresh."""
        path = check_sync_folder(value, self.root)
        if path == self.mirror.root:
            return path
        try:
            config = json.loads((self.root / "config.json").read_text())
        except (OSError, ValueError):
            config = {}
        config["syncFolder"] = str(path)
        write_private(self.root / "config.json", json.dumps(config))
        self.mirror.set_root(path)
        now = time.time() - 3600
        for nid in self.ids():
            if nid not in self.deleted:
                self.mirror_due[nid] = now
        return path

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
        self.mirror_due[nid] = time.time()
        self._summaries.pop(nid, None)

    def delete(self, nid, t):
        if not N.clean_id(nid):
            return
        self.deleted[nid] = max(int(t or 0), self.deleted.get(nid, 0))
        self.cache.pop(nid, None)
        self.dirty.discard(nid)
        self._summaries.pop(nid, None)
        self.mirror_due.pop(nid, None)
        trash = private_dir(self.root / "trash")
        src = self.nb_dir / f"{nid}.json"
        if src.exists():  # kept for a while in case the delete was a mistake
            os.replace(src, trash / f"{nid}-{int(time.time())}.json")
        self.mirror.remove(nid, trash, int(time.time()))
        write_private(self.nb_dir / "deleted.json", json.dumps(self.deleted))

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

    def mirror_items(self, force=False, quiet_for=5.0):
        """Notebooks to copy into the sync folder: those that stopped changing a
        few seconds ago (or all pending ones, when forced)."""
        now = time.time()
        out = []
        for nid, t in list(self.mirror_due.items()):
            if not force and now - t < quiet_for:
                continue
            nb = self.get(nid)
            self.mirror_due.pop(nid, None)
            if not nb:
                continue
            files = {sha: self.asset_dir / sha for sha in N.assets(nb) if self.has_asset(sha)}
            out.append((nid, nb["title"], nb.get("folder", ""), json.dumps(nb, separators=(",", ":")), files))
        return out

    def write_mirror(self, items):
        for nid, title, folder, data, files in items:
            try:
                self.mirror.update(nid, title, folder, data, files)
            except OSError as e:
                sys.stderr.write(f"openpad: couldn't update the sync folder for {title!r}: {e}\n")
                self.mirror_due.setdefault(nid, time.time())

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

    def write_section_pdf(self, nid, sid, data: bytes, digest=""):
        """Save one section as <sync folder>/<folder>/<Notebook>/<Section>.pdf."""
        nb = self.get(nid)
        sec = next((s for s in nb["layout"]["sections"] if s["id"] == sid), None) if nb else None
        if not sec:
            raise ValueError("unknown section")
        if not data.startswith(b"%PDF-"):
            raise ValueError("not a PDF")
        live = {s["id"] for s in nb["layout"]["sections"]}
        return self.mirror.write_pdf(nid, nb["title"], nb.get("folder", ""), sid, sec["title"], live, data,
                                     digest if re.fullmatch(r"[0-9a-f]{8,64}", digest or "") else "")

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
                               "size": "wide", "folder": "", "metaT": t, "created": t,
                               "layout": {"t": t, "sections": [{"id": sec, "title": "Board", "pages": order}]},
                               "goneP": [], "pages": pages})
                self.put(nb)
                self.write_out(self.flush())
        os.replace(legacy, self.root / "session.json.migrated")
        for f in list(self.root.glob("pdf-*")) + list(self.root.glob("img-*.jpg")):
            shutil.rmtree(f, ignore_errors=True) if f.is_dir() else f.unlink(missing_ok=True)
        return nb["id"] if nb else None
