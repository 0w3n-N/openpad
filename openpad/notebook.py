"""Notebooks: validation and merging.

A notebook has sections, and each section lists its pages in order. The same
notebook can be edited on the iPad (offline too), on the computer and by guests
in a live session, so copies are merged instead of overwritten:

  * Ink strokes never change once drawn, only get removed. A page keeps the
    stroke ids it removed ("gone"); merging two copies takes every stroke from
    both and drops the removed ones. Nothing drawn on either side is lost.
  * Titles, page settings (paper, background, size) and the section layout are
    last-writer-wins, by the millisecond timestamp stored next to them.
  * Deleted pages are remembered ("goneP") so they stay deleted.

web/model.js implements the same rules; tests/run.py checks they agree.
"""

from __future__ import annotations

import hashlib
import math
import re
import secrets
import time

PAGE_W = 1000  # page coordinates: width is always 1000 units

MAX_PAGES = 2000
MAX_SECTIONS = 200
MAX_STROKES_PER_PAGE = 20000
MAX_POINTS_PER_STROKE = 50000
MAX_GONE_PER_PAGE = 200000
MAX_IDS_PER_MESSAGE = 20000

PAPERS = ("blank", "grid", "lines", "dots", "eng")
TOOLS = ("pen", "hl")
SIZES = {  # page shapes: height for a 1000-wide page, and the PDF size in points
    "letter": (1294.12, (612, 792)),
    "a4": (1414.29, (595.28, 841.89)),
    "wide": (562.5, (960, 540)),
}
ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,40}$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
BY_RE = re.compile(r"^g[A-Za-z0-9_-]{1,40}$")


def now_ms() -> int:
    return int(time.time() * 1000)


def new_id() -> str:
    return secrets.token_hex(6)


# --------------------------------------------------------------------------- validation


def num(v, lo, hi):
    """A finite number clamped to [lo, hi], or None."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    if not math.isfinite(v):
        return None
    return min(hi, max(lo, v))


def stamp(v):
    """A millisecond timestamp (or 0)."""
    t = num(v, 0, 1e14)
    return int(t) if t else 0


def clean_id(v):
    return v if isinstance(v, str) and ID_RE.match(v) else None


def clean_text(v, default="", limit=120):
    text = re.sub(r"[\x00-\x1f\x7f]", "", str(v if v is not None else default)).strip()
    return (text or default)[:limit]


def clean_point(p):
    if not isinstance(p, (list, tuple)) or len(p) < 2:
        return None
    x, y = num(p[0], -1e5, 1e5), num(p[1], -1e5, 1e5)
    if x is None or y is None:
        return None
    pr = num(p[2], 0, 1) if len(p) > 2 else None
    return [round(x, 2), round(y, 2), round(0.5 if pr is None else pr, 3)]


def clean_points(pts, room):
    if not isinstance(pts, list) or room <= 0:
        return []
    out = []
    for p in pts[:room]:
        c = clean_point(p)
        if c:
            out.append(c)
    return out


def clean_stroke(s):
    if not isinstance(s, dict) or not clean_id(s.get("id")):
        return None
    color = s.get("color")
    out = {
        "id": s["id"],
        "z": num(s.get("z"), 0, 1e17) or 0,
        "tool": s.get("tool") if s.get("tool") in TOOLS else "pen",
        "color": color if isinstance(color, str) and COLOR_RE.match(color) else "#111111",
        "width": num(s.get("width"), 0.5, 80) or 3.5,
        "pts": clean_points(s.get("pts"), MAX_POINTS_PER_STROKE),
    }
    if isinstance(s.get("by"), str) and BY_RE.match(s["by"]):
        out["by"] = s["by"]  # drawn by a guest
    return out


def clean_bg(bg):
    """A page background: a PDF page, an image (a frozen window), or a live window."""
    if not isinstance(bg, dict):
        return None
    n = bg.get("n")
    if isinstance(bg.get("pdf"), str) and SHA_RE.match(bg["pdf"]) \
            and isinstance(n, int) and not isinstance(n, bool) and 1 <= n <= 100000:
        return {"pdf": bg["pdf"], "n": n}
    if isinstance(bg.get("img"), str) and SHA_RE.match(bg["img"]):
        return {"img": bg["img"]}
    if bg.get("live") is True:
        return {"live": True}
    return None


def clean_meta(p):
    """The last-writer-wins part of a page."""
    pt = p.get("pt") if isinstance(p.get("pt"), list) and len(p.get("pt")) == 2 else None
    pt = [num(pt[0], 1, 1e5) or 612, num(pt[1], 1, 1e5) or 792] if pt else [612, 792]
    return {
        "t": stamp(p.get("t")),
        "sec": clean_id(p.get("sec")) or "",
        "w": PAGE_W,
        "h": num(p.get("h"), 10, 100000) or SIZES["letter"][0],
        "paper": p.get("paper") if p.get("paper") in PAPERS else "blank",
        "bg": clean_bg(p.get("bg")),
        "pt": [round(pt[0], 2), round(pt[1], 2)],
    }


def clean_page(p, pid=None):
    if not isinstance(p, dict):
        return None
    pid = clean_id(p.get("id")) or clean_id(pid)
    if not pid:
        return None
    gone = p.get("gone") if isinstance(p.get("gone"), list) else []
    gone = sorted({g for g in gone[:MAX_GONE_PER_PAGE] if clean_id(g)})
    gone_set = set(gone)
    strokes, seen = [], set()
    for s in (p.get("strokes") if isinstance(p.get("strokes"), list) else [])[:MAX_STROKES_PER_PAGE]:
        c = clean_stroke(s)
        if c and c["id"] not in seen and c["id"] not in gone_set:
            seen.add(c["id"])
            strokes.append(c)
    strokes.sort(key=lambda s: (s["z"], s["id"]))
    return {"id": pid, **clean_meta(p), "strokes": strokes, "gone": gone}


def clean_layout(layout):
    if not isinstance(layout, dict):
        return {"t": 0, "sections": []}
    secs, seen_s, seen_p = [], set(), set()
    for s in (layout.get("sections") if isinstance(layout.get("sections"), list) else [])[:MAX_SECTIONS]:
        if not isinstance(s, dict) or not clean_id(s.get("id")) or s["id"] in seen_s:
            continue
        seen_s.add(s["id"])
        pages = []
        for pid in (s.get("pages") if isinstance(s.get("pages"), list) else [])[:MAX_PAGES]:
            if clean_id(pid) and pid not in seen_p:
                seen_p.add(pid)
                pages.append(pid)
        secs.append({"id": s["id"], "title": clean_text(s.get("title"), "Section", 80), "pages": pages})
    return {"t": stamp(layout.get("t")), "sections": secs}


def clean_notebook(nb, partial=False):
    """Validate a notebook from a client. A partial one (a live edit) may leave
    out whatever didn't change; its timestamps decide what wins on merge."""
    if not isinstance(nb, dict) or not clean_id(nb.get("id")):
        return None
    raw_pages = nb.get("pages") if isinstance(nb.get("pages"), dict) else {}
    pages = {}
    for pid, p in list(raw_pages.items())[:MAX_PAGES]:
        c = clean_page(p, pid)
        if c and c["id"] == pid:
            pages[pid] = c
    gone_p = nb.get("goneP") if isinstance(nb.get("goneP"), list) else []
    out = {
        "v": 1,
        "id": nb["id"],
        "title": clean_text(nb.get("title"), "Untitled notebook", 120),
        "size": nb.get("size") if nb.get("size") in SIZES else "letter",
        "metaT": stamp(nb.get("metaT")),
        "created": stamp(nb.get("created")),
        "layout": clean_layout(nb.get("layout")),
        "goneP": sorted({g for g in gone_p[:MAX_PAGES * 4] if clean_id(g)}),
        "pages": pages,
    }
    if partial:
        if "title" not in nb and "size" not in nb:
            out["metaT"] = 0
        if "layout" not in nb:
            out["layout"] = {"t": 0, "sections": []}
    return finish(out) if not partial else out


# --------------------------------------------------------------------------- merge


def _meta_key(p):
    # Ties (same millisecond) break on plain strings so web/model.js agrees.
    bg = p["bg"] or {}
    return (p["t"], f'{p["sec"]}|{p["paper"]}|{bg.get("pdf") or bg.get("img") or ("live" if bg.get("live") else "")}|{bg.get("n", "")}')


def _layout_key(layout):
    return (layout["t"], "|".join(f'{s["id"]}:{s["title"]}:{",".join(s["pages"])}' for s in layout["sections"]))


def _merge_page(a, b):
    meta = a if _meta_key(a) >= _meta_key(b) else b
    gone = set(a["gone"]) | set(b["gone"])
    strokes = {}
    for s in a["strokes"] + b["strokes"]:
        if s["id"] in gone:
            continue
        old = strokes.get(s["id"])
        if old is None or len(s["pts"]) > len(old["pts"]):
            strokes[s["id"]] = s  # mid-stroke copies: keep the longer one
    out = {k: meta[k] for k in ("t", "sec", "w", "h", "paper", "bg", "pt")}
    out["id"] = a["id"]
    out["strokes"] = sorted(strokes.values(), key=lambda s: (s["z"], s["id"]))[:MAX_STROKES_PER_PAGE]
    out["gone"] = sorted(gone)[:MAX_GONE_PER_PAGE]
    return out


def merge(a, b):
    """Merge two copies of the same notebook. Order doesn't matter, and merging
    a copy into itself changes nothing."""
    if a is None:
        return b
    if b is None:
        return a
    out = {"v": 1, "id": a["id"]}
    meta = a if (a["metaT"], a["title"], a["size"]) >= (b["metaT"], b["title"], b["size"]) else b
    out["title"], out["size"], out["metaT"] = meta["title"], meta["size"], meta["metaT"]
    created = [c for c in (a["created"], b["created"]) if c]
    out["created"] = min(created) if created else 0
    la, lb = a["layout"], b["layout"]
    out["layout"] = la if _layout_key(la) >= _layout_key(lb) else lb
    gone_p = set(a["goneP"]) | set(b["goneP"])
    out["goneP"] = sorted(gone_p)
    pages = {}
    for pid in set(a["pages"]) | set(b["pages"]):
        if pid in gone_p:
            continue
        pa, pb = a["pages"].get(pid), b["pages"].get(pid)
        pages[pid] = _merge_page(pa, pb) if pa and pb else (pa or pb)
    out["pages"] = pages
    return finish(out)


def finish(nb):
    """Make the layout list exactly the live pages: drop deleted or unknown
    ones, and put pages that aren't listed (added on another device while this
    layout was written) at the end of their section."""
    alive = {pid for pid in nb["pages"] if pid not in set(nb["goneP"])}
    seen = set()
    sections = []
    for s in nb["layout"]["sections"]:
        pages = [pid for pid in s["pages"] if pid in alive and pid not in seen]
        seen.update(pages)
        sections.append({"id": s["id"], "title": s["title"], "pages": pages})
    if not sections:
        sections = [{"id": "main", "title": "Notes", "pages": []}]
    by_id = {s["id"]: s for s in sections}
    for pid in sorted(alive - seen):
        by_id.get(nb["pages"][pid]["sec"], sections[-1])["pages"].append(pid)
    nb["layout"] = {"t": nb["layout"]["t"], "sections": sections}
    for pid in list(nb["pages"]):
        if pid not in alive:
            del nb["pages"][pid]
    return nb


def digest(nb) -> str:
    """Changes whenever the notebook's content does; equal for equal content.
    web/model.js computes the same value, so sync can skip unchanged notebooks."""
    parts = [f"m:{nb['metaT']}", f"l:{nb['layout']['t']}", "g:" + ",".join(nb["goneP"])]
    for pid in sorted(nb["pages"]):
        p = nb["pages"][pid]
        ink = ",".join(sorted(f"{s['id']}.{len(s['pts'])}" for s in p["strokes"]))
        parts.append(f"p:{pid}:{p['t']}:{ink}:{','.join(p['gone'])}")
    return hashlib.sha256("\n".join(parts).encode()).hexdigest()[:32]


def assets(nb) -> set[str]:
    """Files (PDFs, images) the notebook's pages show."""
    out = set()
    for p in nb["pages"].values():
        bg = p["bg"] or {}
        if bg.get("pdf"):
            out.add(bg["pdf"])
        if bg.get("img"):
            out.add(bg["img"])
    return out


# --------------------------------------------------------------------------- building


def blank_page(sec, size="letter", paper="lines", t=None):
    h, pt = SIZES.get(size, SIZES["letter"])
    return {"id": new_id(), "t": t or now_ms(), "sec": sec, "w": PAGE_W, "h": h, "paper": paper,
            "bg": None, "pt": list(pt), "strokes": [], "gone": []}


def new_notebook(title="Notebook", size="letter", section="Notes", paper="lines"):
    t = now_ms()
    sec = new_id()
    page = blank_page(sec, size, paper, t)
    return finish({"v": 1, "id": new_id(), "title": title, "size": size, "metaT": t, "created": t,
                   "layout": {"t": t, "sections": [{"id": sec, "title": section, "pages": [page["id"]]}]},
                   "goneP": [], "pages": {page["id"]: page}})


def order(nb):
    """Page ids in reading order."""
    return [pid for s in nb["layout"]["sections"] for pid in s["pages"]]


def summary(nb):
    return {"id": nb["id"], "title": nb["title"], "t": max([nb["metaT"], nb["layout"]["t"]] +
                                                          [p["t"] for p in nb["pages"].values()]),
            "pages": len(nb["pages"]), "d": digest(nb)}
