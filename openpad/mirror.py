"""The sync folder: a browsable, self-contained copy of every notebook.

    <sync folder>/<folder>/<notebook>/
        <section>.pdf              readable, ink included (rendered by the iPad)
        .openpad/notebook.json     the notebook itself (layout, pages, ink)
        .openpad/files/<sha>.pdf   the PDFs and images its pages show

Folders follow the notebook's own folder ("2025 Fall/ECE 210"), and move or
rename when it does. The folder is chosen by the user (`openpad sync-folder`,
the share window, or the Omarchy widget); changing it starts a fresh copy
there and leaves the old one alone.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import threading
from pathlib import Path

WINDOWS = os.name == "nt"
RESERVED = {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(10)), *(f"LPT{i}" for i in range(10))}


def safe_name(text, fallback):
    """One path segment: no separators, control or reserved characters, and
    never starting or ending with a dot (so never "." or "..")."""
    name = re.sub(r'[\x00-\x1f\x7f<>:"/\\|?*]', "", str(text)).strip().strip(".").strip()
    if name.upper() in RESERVED:
        name = ""
    return (name or fallback)[:80]


def file_type(path: Path) -> str:
    try:
        with open(path, "rb") as f:
            head = f.read(8)
    except OSError:
        return ""
    if head.startswith(b"%PDF"):
        return ".pdf"
    if head.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if head.startswith(b"\x89PNG"):
        return ".png"
    return ""


class Mirror:
    def __init__(self, state_dir: Path, root: Path, write_private):
        self.state = state_dir / "mirror.json"
        self.write_private = write_private
        self.lock = threading.Lock()
        self.root = root
        self.map: dict[str, dict] = {}  # nb id -> {"dir": relative path, "sections": {sid: {"file", "d"}}}
        try:
            saved = json.loads(self.state.read_text())
            if saved.get("root") == str(root):
                self.map = {k: v for k, v in saved.get("notebooks", {}).items() if isinstance(v, dict)}
        except (OSError, ValueError, AttributeError):
            self.map = self._from_legacy(state_dir / "folders.json", root)

    @staticmethod
    def _from_legacy(path: Path, root: Path):
        """0.5.0 kept {nb: {dir, sections: {sid: file}}} in folders.json."""
        try:
            old = json.loads(path.read_text())
        except (OSError, ValueError):
            return {}
        out = {}
        for nid, e in (old.items() if isinstance(old, dict) else []):
            if isinstance(e, dict) and isinstance(e.get("dir"), str):
                secs = {sid: {"file": f, "d": ""} for sid, f in (e.get("sections") or {}).items() if isinstance(f, str)}
                out[nid] = {"dir": e["dir"], "sections": secs}
        return out

    def _save(self):
        self.write_private(self.state, json.dumps({"root": str(self.root), "notebooks": self.map}))

    def _mkdir(self, d: Path):
        """Create d and missing parents; directories OpenPad creates are owner-only."""
        missing = []
        p = d
        while not p.exists() and p != p.parent:
            missing.append(p)
            p = p.parent
        for p in reversed(missing):
            p.mkdir(mode=0o700)
            if not WINDOWS:
                os.chmod(p, 0o700)

    def _prune(self, d: Path):
        """Remove empty folders left behind by a move, up to the root."""
        try:
            while d != self.root and self.root in d.parents and d.is_dir() and not any(d.iterdir()):
                d.rmdir()
                d = d.parent
        except OSError:
            pass

    def set_root(self, root: Path):
        with self.lock:
            self.root = root
            self.map = {}
            self._save()

    def _target(self, nid, title, folder):
        segments = [safe_name(seg, "Folder") for seg in folder.split("/") if seg.strip()]
        want = "/".join(segments + [safe_name(title, "Notebook")])
        taken = {e["dir"] for k, e in self.map.items() if k != nid}
        if want in taken:
            want = f"{want} ({nid[:4]})"
        return want

    def _place(self, nid, title, folder):
        """The notebook's folder in the copy, moved if its title or folder changed."""
        entry = self.map.get(nid) or {"dir": "", "sections": {}}
        want = self._target(nid, title, folder)
        if entry["dir"] != want:
            old, new = self.root / entry["dir"], self.root / want
            if entry["dir"] and old.is_dir() and not new.exists():
                self._mkdir(new.parent)
                shutil.move(str(old), str(new))
                self._prune(old.parent)
            entry["dir"] = want
        self._mkdir(self.root / want)
        self.map[nid] = entry
        return entry, self.root / want

    def update(self, nid, title, folder, data: str, assets: dict[str, Path]):
        """Write a notebook's data and files into the copy. `assets` maps each
        file's hash to where it's stored."""
        with self.lock:
            entry, d = self._place(nid, title, folder)
            meta = d / ".openpad"
            files = meta / "files"
            self._mkdir(files)
            self.write_private(meta / "notebook.json", data)
            keep = set()
            for sha, src in assets.items():
                ext = file_type(src)
                if not ext:
                    continue
                target = files / f"{sha}{ext}"
                keep.add(target.name)
                if target.exists():
                    continue
                try:
                    os.link(src, target)  # same disk: no second copy
                except OSError:
                    shutil.copyfile(src, target)
                    if not WINDOWS:
                        os.chmod(target, 0o600)
            for f in files.iterdir():
                if f.name not in keep:
                    f.unlink(missing_ok=True)
            self._save()

    def write_pdf(self, nid, title, folder, sid, section_title, live_sections, data: bytes, digest: str):
        """Save one section as <section>.pdf in the notebook's folder."""
        with self.lock:
            entry, d = self._place(nid, title, folder)
            name = safe_name(section_title, "Section")
            others = {e["file"] for k, e in entry["sections"].items() if k != sid}
            if f"{name}.pdf" in others:
                name = f"{name} ({sid[:4]})"
            old = entry["sections"].get(sid)
            if old and old["file"] != f"{name}.pdf":
                (d / old["file"]).unlink(missing_ok=True)  # the section was renamed
            entry["sections"][sid] = {"file": f"{name}.pdf", "d": digest}
            # Sections that no longer exist: their PDFs go too.
            for gone in [k for k in entry["sections"] if k not in live_sections]:
                (d / entry["sections"].pop(gone)["file"]).unlink(missing_ok=True)
            self.write_private(d / f"{name}.pdf", data)
            self._save()
            return d / f"{name}.pdf"

    def remove(self, nid, trash: Path, stamp: int):
        """A deleted notebook's folder goes to OpenPad's trash (not the copy)."""
        with self.lock:
            entry = self.map.pop(nid, None)
            if entry and entry["dir"] and (self.root / entry["dir"]).is_dir():
                src = self.root / entry["dir"]
                try:
                    shutil.move(str(src), str(trash / f"{safe_name(Path(entry['dir']).name, 'Notebook')}-{stamp}"))
                    self._prune(src.parent)
                except OSError:
                    pass
            self._save()

    def pdf_digests(self):
        with self.lock:
            return {nid: {sid: s.get("d", "") for sid, s in e["sections"].items()} for nid, e in self.map.items()}
