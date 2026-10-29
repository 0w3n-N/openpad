// The page editor: Pencil/mouse/finger input, tools, undo, zoom and pan.
// Used by the notes app (owner) and guest pages. The editor changes the
// notebook in memory and reports every change through `onop(msg)`, which the
// host saves and/or sends to the live session.

import { NEUTRAL_PRESSURE, Surface, shapePressure, strokeBounds, strokeHit } from './ink.js';
import { applyOp, blankPage, indexStrokes, newId, now, order, sectionOf } from './model.js';

const HL_WIDTH = { 2: 14, 3.5: 22, 6.5: 34 };
const ERASER_R = 10;
// Apple Pencil's barrel double-tap is not exposed to web pages, so a quick
// double-tap of the tip on the same spot toggles pen <-> eraser instead.
const TAP_MAX_MS = 200;
const TAP_MAX_PX = 6;
const DOUBLE_TAP_GAP_MS = 300;
const DOUBLE_TAP_PX = 16;
// Hold the pen still at the end of a stroke to turn it into a straight line.
const HOLD_MS = 550;
const HOLD_PX = 4;

let zCounter = 0;
const nextZ = () => Date.now() * 1000 + (zCounter++ % 1000);
const reid = (strokes) => strokes.map((s) => ({ ...s, id: newId(), pts: s.pts.map((p) => [...p]) }));

export class Editor {
  constructor(stage, { backgrounds, settings, onop, onpage, toast, canDraw = true, canEdit = true, by = null }) {
    this.stage = stage;
    this.surface = new Surface(stage, backgrounds);
    this.settings = settings; // {pressure: 0..1, doubleTap, fingerDraw}
    this.onop = onop;
    this.onpage = onpage || (() => {});
    this.toast = toast || (() => {});
    this.canDraw = canDraw;
    this.canEdit = canEdit; // pages, paper, clearing: the owner only
    this.by = by; // guests: only their own strokes can be erased
    this.nb = null;
    this.idx = new Map();
    this.pid = null;
    this.tool = 'pen';
    this.lastTool = 'pen';
    this.shape = 'line';
    this.color = '#111111';
    this.width = 3.5;
    this.undo = [];
    this.redo = [];
    this.drawing = null;
    this.pending = [];
    this.eraserAt = null;
    this.lastTap = null;
    this.touches = new Map();
    this.gesture = null;
    this.zoomed = false;
    this.selection = null; // {page, ids, box, drag}
    this.lasso = null;
    this.follow = null; // set by the host: page changes from others to follow
    this.surface.overlay = (ctx, k) => this.#overlay(ctx, k);
    // Re-measure whenever the stage changes size: rotation, the sidebar, or
    // a page that loaded in a background tab (0x0 until it's shown).
    new ResizeObserver(() => {
      const r = stage.getBoundingClientRect();
      if (r.width && r.height && (r.width !== this.surface.cw || r.height !== this.surface.ch)) this.layout();
    }).observe(stage);
    this.#bind();
    this.#selectionBar();
  }

  // ---------------------------------------------------------------- notebook & pages

  get page() {
    return this.nb?.pages[this.pid] || null;
  }

  setNotebook(nb, pid) {
    const same = this.nb && this.nb.id === nb.id;
    this.nb = nb;
    this.idx = indexStrokes(nb);
    if (!same) {
      this.undo = [];
      this.redo = [];
    }
    this.#keepDrawing();
    const ids = order(nb);
    this.show(nb.pages[pid] ? pid : nb.pages[this.pid] ? this.pid : ids[0], !same || pid !== this.pid);
  }

  // A full new copy of the same notebook arrived (merged elsewhere).
  refresh() {
    this.idx = indexStrokes(this.nb);
    this.#keepDrawing();
    if (!this.nb.pages[this.pid]) this.show(order(this.nb)[0], true);
    else this.show(this.pid, false);
  }

  #keepDrawing() {
    // Keep the stroke being drawn right now (another copy may lag behind).
    const d = this.drawing;
    if (!d?.stroke) return;
    const page = this.nb.pages[d.page];
    if (!page) return (this.drawing = null);
    const i = page.strokes.findIndex((s) => s.id === d.stroke.id);
    if (i >= 0) page.strokes[i] = d.stroke;
    else if (!page.gone.includes(d.stroke.id)) page.strokes.push(d.stroke);
    this.idx.set(d.stroke.id, [d.stroke, page]);
  }

  show(pid, refit = true) {
    if (!this.nb?.pages[pid]) return;
    const changed = pid !== this.pid;
    this.pid = pid;
    if (changed) this.clearSelection();
    this.surface.active.clear();
    if (this.drawing?.stroke && this.drawing.page === pid) this.surface.active.set(this.drawing.stroke.id, this.drawing.stroke);
    if (refit) this.fit();
    this.surface.setPage(this.page);
    this.onpage(pid, changed);
  }

  fit() {
    const p = this.page;
    if (!p) return;
    // Portrait pages fit the width (scroll down); wide ones fit whole.
    if (p.h / p.w > 1.05 && this.surface.ch / this.surface.cw < p.h / p.w) this.surface.fitWidth(p, 12);
    else this.surface.fit(p, 12);
    this.#setZoomed(false);
  }

  goto(delta) {
    const ids = order(this.nb);
    const i = ids.indexOf(this.pid) + delta;
    if (i < 0 || i >= ids.length) return false;
    this.show(ids[i], true);
    this.onop({ t: 'goto', page: ids[i] });
    return true;
  }

  gotoPage(pid) {
    if (pid === this.pid || !this.nb.pages[pid]) return;
    this.show(pid, true);
    this.onop({ t: 'goto', page: pid });
  }

  position() {
    const ids = order(this.nb);
    const sec = sectionOf(this.nb, this.pid);
    return { index: ids.indexOf(this.pid), count: ids.length, section: sec, inSection: sec ? sec.pages.indexOf(this.pid) : 0 };
  }

  // Structural edits are sent as partial notebooks (merge messages).
  #layoutChange(mutate, pages = [], goneP = []) {
    const t = now();
    const layout = { t, sections: this.nb.layout.sections.map((s) => ({ ...s, pages: [...s.pages] })) };
    mutate(layout.sections);
    this.nb.layout = layout;
    for (const id of goneP) {
      delete this.nb.pages[id];
      if (!this.nb.goneP.includes(id)) this.nb.goneP.push(id);
    }
    this.nb.goneP.sort();
    this.idx = indexStrokes(this.nb);
    this.onop({ t: 'merge', nb: { id: this.nb.id, layout, goneP, pages: Object.fromEntries(pages.map((p) => [p.id, { ...p, strokes: [], gone: [] }])) } }, { pages: pages.map((p) => p.id), structural: true });
  }

  addPage(after = this.pid, opts = {}) {
    if (!this.canEdit) return null;
    const cur = this.nb.pages[after] || this.page;
    const sec = sectionOf(this.nb, after) || this.nb.layout.sections[this.nb.layout.sections.length - 1];
    const page = blankPage(sec.id, this.nb.size, opts.paper || (cur && !cur.bg ? cur.paper : 'lines'));
    if (cur && !cur.bg && !opts.size) {
      page.h = cur.h;
      page.pt = [...cur.pt];
    }
    Object.assign(page, opts.page || {});
    this.nb.pages[page.id] = page;
    this.#layoutChange((secs) => {
      const s = secs.find((x) => x.id === sec.id);
      const i = s.pages.indexOf(after);
      s.pages.splice(i < 0 ? s.pages.length : i + 1, 0, page.id);
    }, [page]);
    this.gotoPage(page.id);
    return page;
  }

  deletePage(pid = this.pid) {
    if (!this.canEdit || order(this.nb).length <= 1) return false;
    const ids = order(this.nb);
    const next = ids[ids.indexOf(pid) + 1] || ids[ids.indexOf(pid) - 1];
    this.#layoutChange((secs) => secs.forEach((s) => (s.pages = s.pages.filter((x) => x !== pid))), [], [pid]);
    this.undo = this.undo.filter((op) => op.page !== pid);
    this.redo = this.redo.filter((op) => op.page !== pid);
    this.syncUndo?.();
    this.show(next, true);
    this.onop({ t: 'goto', page: next });
    return true;
  }

  movePage(pid, secId, index) {
    if (!this.canEdit) return;
    const page = this.nb.pages[pid];
    page.sec = secId;
    page.t = now();
    this.#layoutChange((secs) => {
      secs.forEach((s) => (s.pages = s.pages.filter((x) => x !== pid)));
      const s = secs.find((x) => x.id === secId);
      s.pages.splice(Math.max(0, Math.min(index, s.pages.length)), 0, pid);
    }, [page]);
    this.onpage(this.pid, false);
  }

  addSection(title) {
    if (!this.canEdit) return null;
    const id = newId();
    const page = blankPage(id, this.nb.size, this.page && !this.page.bg ? this.page.paper : 'lines');
    this.nb.pages[page.id] = page;
    const cur = sectionOf(this.nb, this.pid);
    this.#layoutChange((secs) => {
      const i = secs.findIndex((s) => s.id === cur?.id);
      secs.splice(i < 0 ? secs.length : i + 1, 0, { id, title, pages: [page.id] });
    }, [page]);
    this.gotoPage(page.id);
    return id;
  }

  renameSection(id, title) {
    if (!this.canEdit) return;
    this.#layoutChange((secs) => {
      const s = secs.find((x) => x.id === id);
      if (s) s.title = title;
    });
    this.onpage(this.pid, false);
  }

  deleteSection(id) {
    if (!this.canEdit || this.nb.layout.sections.length <= 1) return false;
    const sec = this.nb.layout.sections.find((s) => s.id === id);
    if (!sec) return false;
    const gone = [...sec.pages];
    const wasHere = gone.includes(this.pid);
    this.#layoutChange((secs) => secs.splice(secs.findIndex((s) => s.id === id), 1), [], gone);
    if (wasHere) {
      const first = order(this.nb)[0];
      this.show(first, true);
      this.onop({ t: 'goto', page: first });
    } else this.onpage(this.pid, false);
    return true;
  }

  moveSection(id, delta) {
    if (!this.canEdit) return;
    this.#layoutChange((secs) => {
      const i = secs.findIndex((s) => s.id === id);
      const j = i + delta;
      if (i < 0 || j < 0 || j >= secs.length) return;
      [secs[i], secs[j]] = [secs[j], secs[i]];
    });
    this.onpage(this.pid, false);
  }

  setPaper(paper) {
    const p = this.page;
    if (!this.canEdit || !p) return;
    p.paper = paper;
    p.t = now();
    this.onop({ t: 'merge', nb: { id: this.nb.id, goneP: [], pages: { [p.id]: { ...p, strokes: [], gone: [] } } } }, { pages: [p.id], structural: true });
    this.surface.drawBg();
  }

  clearPage() {
    const p = this.page;
    if (!p) return;
    const strokes = p.strokes.filter((s) => this.#mayErase(s));
    if (!strokes.length) return;
    this.#remove(p.id, strokes.map((s) => s.id));
    this.#push({ page: p.id, removed: strokes, added: [] });
  }

  // ---------------------------------------------------------------- remote edits

  applyRemote(msg) {
    const page = applyOp(this.nb, this.idx, msg);
    const here = page && page.id === this.pid;
    if (msg.t === 'begin' && here) this.surface.active.set(msg.s.id, this.idx.get(msg.s.id)[0]);
    if (msg.t === 'pts' && here) this.surface.queueLive();
    if (msg.t === 'end') {
      const e = this.idx.get(msg.id);
      if (e && this.surface.active.has(msg.id)) this.surface.commit(e[0]);
    }
    if ((msg.t === 'remove' || msg.t === 'restore') && here) {
      if (this.selection && msg.t === 'remove') this.selection.ids = this.selection.ids.filter((i) => !msg.ids.includes(i));
      this.surface.drawInk();
      this.surface.queueLive();
    }
    return page;
  }

  // ---------------------------------------------------------------- tools

  setTool(t) {
    if (t === 'eraser' && this.tool !== 'eraser') this.lastTool = this.tool;
    if (t !== 'lasso') this.clearSelection();
    this.tool = t;
  }
  toggleEraser() {
    this.setTool(this.tool === 'eraser' ? this.lastTool : 'eraser');
    this.toast(this.tool === 'eraser' ? 'Eraser' : this.tool === 'hl' ? 'Highlighter' : 'Pen', 700);
    this.ontool?.(this.tool);
  }

  #mayErase(s) {
    return !this.by || s.by === this.by;
  }

  #emitStrokeOps(pageId, removedIds, added) {
    if (removedIds.length) this.onop({ t: 'remove', page: pageId, ids: removedIds }, { pages: [pageId] });
    if (added.length) this.onop({ t: 'restore', page: pageId, strokes: added }, { pages: [pageId] });
  }

  #remove(pageId, ids) {
    applyOp(this.nb, this.idx, { t: 'remove', page: pageId, ids });
    ids.forEach((i) => this.surface.active.delete(i));
    this.onop({ t: 'remove', page: pageId, ids }, { pages: [pageId] });
    if (this.pid === pageId) {
      this.surface.drawInk();
      this.surface.queueLive();
    }
  }

  #restore(pageId, strokes) {
    applyOp(this.nb, this.idx, { t: 'restore', page: pageId, strokes });
    this.onop({ t: 'restore', page: pageId, strokes }, { pages: [pageId] });
    if (this.pid === pageId) this.surface.drawInk();
  }

  #push(op) {
    this.undo.push(op);
    if (this.undo.length > 300) this.undo.shift();
    this.redo = [];
    this.syncUndo?.();
  }

  // An undo entry removes some strokes and adds others. Strokes come back
  // under new ids: once removed, an id stays removed everywhere (see model.js).
  #apply(op, inverse) {
    if (!this.nb.pages[op.page]) return false;
    if (op.page !== this.pid) this.gotoPage(op.page);
    const [out, inn] = inverse ? ['added', 'removed'] : ['removed', 'added'];
    const live = op[out].filter((s) => this.idx.has(s.id));
    if (live.length) this.#remove(op.page, live.map((s) => s.id));
    op[inn] = reid(op[inn]);
    if (op[inn].length) this.#restore(op.page, op[inn]);
    this.clearSelection();
    return true;
  }

  doUndo() {
    while (this.undo.length) {
      const op = this.undo.pop();
      if (this.#apply(op, true)) {
        this.redo.push(op);
        break;
      }
    }
    this.syncUndo?.();
  }

  doRedo() {
    while (this.redo.length) {
      const op = this.redo.pop();
      if (this.#apply(op, false)) {
        this.undo.push(op);
        break;
      }
    }
    this.syncUndo?.();
  }

  // ---------------------------------------------------------------- drawing

  #point(e, prev) {
    const r = this.stage.getBoundingClientRect();
    const [x, y] = this.surface.toPage(e.clientX - r.left, e.clientY - r.top);
    const p = e.pointerType === 'pen' ? shapePressure(Math.max(0.05, e.pressure || 0.5), this.settings.pressure, prev) : NEUTRAL_PRESSURE;
    return [Math.round(x * 100) / 100, Math.round(y * 100) / 100, Math.round(p * 1000) / 1000];
  }

  #capture(e) {
    try {
      this.stage.setPointerCapture(e.pointerId);
    } catch {}
  }

  #start(e) {
    const page = this.page;
    if (!page) return;
    const pt = this.#point(e);
    this.#capture(e);
    const base = { pointerId: e.pointerId, pointerType: e.pointerType, page: page.id, t0: performance.now(), x0: e.clientX, y0: e.clientY, moved: 0, start: pt };
    if (this.tool === 'lasso') {
      if (this.selection && this.#inBox(pt)) {
        this.drawing = { ...base, kind: 'move', from: pt };
        this.selection.drag = [0, 0];
        return;
      }
      this.clearSelection();
      this.drawing = { ...base, kind: 'lasso' };
      this.lasso = [pt];
      return;
    }
    if (this.tool === 'eraser') {
      this.drawing = { ...base, kind: 'erase', removed: [] };
      this.#eraseAt(pt);
      return;
    }
    if (this.tool === 'shape') {
      this.drawing = { ...base, kind: 'shape', stroke: { id: newId(), z: nextZ(), tool: 'pen', color: this.color, width: this.width, pts: [pt] } };
      return;
    }
    const s = {
      id: newId(), z: nextZ(), tool: this.tool,
      color: this.tool === 'hl' && this.color === '#111111' ? '#ffd400' : this.color,
      width: this.tool === 'hl' ? HL_WIDTH[this.width] || 22 : this.width,
      pts: [pt],
    };
    if (this.by) s.by = this.by;
    page.strokes.push(s);
    this.idx.set(s.id, [s, page]);
    this.drawing = { ...base, kind: 'ink', stroke: s, still: { t: performance.now(), x: e.clientX, y: e.clientY } };
    this.surface.active.set(s.id, s);
    this.onop({ t: 'begin', page: page.id, s: { ...s, pts: [...s.pts] } }, { live: true });
    this.surface.queueLive();
    this.#armHold();
  }

  #armHold() {
    clearTimeout(this.holdTimer);
    const d = this.drawing;
    if (!d || d.kind !== 'ink' || d.stroke.tool !== 'pen' || d.straight) return;
    this.holdTimer = setTimeout(() => {
      if (this.drawing !== d || d.moved < 24) return;
      // Held still: snap to a straight line that follows the pen from now on.
      d.straight = true;
      const a = d.stroke.pts[0], b = d.stroke.pts[d.stroke.pts.length - 1];
      d.line = { id: newId(), z: d.stroke.z, tool: 'pen', color: d.stroke.color, width: d.stroke.width, pts: line(a, b) };
      if (this.by) d.line.by = this.by;
      this.surface.active.delete(d.stroke.id);
      this.surface.active.set(d.line.id, d.line);
      this.surface.queueLive();
    }, HOLD_MS);
  }

  #move(e) {
    const d = this.drawing;
    const events = e.getCoalescedEvents ? e.getCoalescedEvents() : [];
    const list = events.length ? events : [e];
    for (const ev of list) d.moved = Math.max(d.moved, Math.hypot(ev.clientX - d.x0, ev.clientY - d.y0));
    if (d.kind === 'erase') {
      for (const ev of list) this.#eraseAt(this.#point(ev));
      return;
    }
    if (d.kind === 'lasso') {
      for (const ev of list) this.lasso.push(this.#point(ev));
      return this.surface.queueLive();
    }
    if (d.kind === 'move') {
      const p = this.#point(e);
      this.selection.drag = [p[0] - d.from[0], p[1] - d.from[1]];
      return this.surface.queueLive();
    }
    if (d.kind === 'shape') {
      d.stroke.pts = shapePoints(this.shape, d.start, this.#point(e));
      return this.surface.queueLive();
    }
    if (d.straight) {
      const p = this.#point(e);
      d.line.pts = line(d.line.pts[0], p);
      return this.surface.queueLive();
    }
    const pts = d.stroke.pts;
    for (const ev of list) {
      const pt = this.#point(ev, pts[pts.length - 1][2]);
      const last = pts[pts.length - 1];
      if (Math.abs(pt[0] - last[0]) + Math.abs(pt[1] - last[1]) < 0.35) continue;
      pts.push(pt);
      this.pending.push(pt);
    }
    if (Math.hypot(e.clientX - d.still.x, e.clientY - d.still.y) > HOLD_PX) {
      d.still = { t: performance.now(), x: e.clientX, y: e.clientY };
      this.#armHold();
    }
    if (!this.flushQueued && this.pending.length) {
      this.flushQueued = true;
      requestAnimationFrame(() => this.#flush());
    }
    this.surface.queueLive();
  }

  #flush() {
    this.flushQueued = false;
    const d = this.drawing;
    if (d?.kind === 'ink' && this.pending.length) this.onop({ t: 'pts', id: d.stroke.id, pts: this.pending }, { live: true });
    this.pending = [];
  }

  #end(cancel = false) {
    clearTimeout(this.holdTimer);
    this.#flush();
    const d = this.drawing;
    this.drawing = null;
    const undoLen = this.undo.length;
    const redoBefore = this.redo.slice();
    if (d.kind === 'ink') {
      if (cancel) {
        this.#remove(d.page, [d.stroke.id]);
        return;
      }
      if (d.straight) {
        // Swap the freehand stroke for the straight line.
        this.surface.active.delete(d.line.id);
        this.#remove(d.page, [d.stroke.id]);
        this.#restore(d.page, [d.line]);
        this.#push({ page: d.page, removed: [], added: [d.line] });
        return;
      }
      this.onop({ t: 'end', id: d.stroke.id }, { pages: [d.page], live: true });
      this.surface.commit(d.stroke);
      this.#push({ page: d.page, removed: [], added: [d.stroke] });
      this.#checkDoubleTap(d, undoLen, redoBefore);
      return;
    }
    if (d.kind === 'shape') {
      if (!cancel && d.moved > 3) {
        this.#restore(d.page, [d.stroke]);
        this.#push({ page: d.page, removed: [], added: [d.stroke] });
      }
      this.surface.queueLive();
      return;
    }
    if (d.kind === 'erase') {
      this.eraserAt = null;
      this.surface.queueLive();
      if (d.removed.length) this.#push({ page: d.page, removed: d.removed, added: [] });
      this.#checkDoubleTap(d, undoLen, redoBefore);
      return;
    }
    if (d.kind === 'lasso') return this.#finishLasso();
    if (d.kind === 'move') return this.#finishMove();
  }

  #checkDoubleTap(d, undoLen, redoBefore) {
    const t = performance.now();
    const isTap = this.settings.doubleTap && d.pointerType === 'pen' && t - d.t0 < TAP_MAX_MS && d.moved < TAP_MAX_PX;
    if (!isTap) {
      this.lastTap = null;
      return;
    }
    const prev = this.lastTap;
    if (prev && d.t0 - prev.up < DOUBLE_TAP_GAP_MS && Math.hypot(d.x0 - prev.x, d.y0 - prev.y) < DOUBLE_TAP_PX) {
      // Take back whatever the two taps did (dots drawn or strokes erased).
      while (this.undo.length > prev.undoLen) this.#apply(this.undo.pop(), true);
      this.redo = prev.redo;
      this.syncUndo?.();
      this.lastTap = null;
      this.toggleEraser();
      return;
    }
    this.lastTap = { up: t, x: d.x0, y: d.y0, undoLen, redo: redoBefore };
  }

  #eraseAt(pt) {
    const page = this.page;
    const r = ERASER_R / Math.max(0.5, this.surface.view.s / this.surface.fitScale(page, 12));
    const prev = this.eraserAt || pt;
    const steps = Math.max(1, Math.ceil(Math.hypot(pt[0] - prev[0], pt[1] - prev[1]) / (r / 2)));
    this.eraserAt = [pt[0], pt[1], r];
    const hits = page.strokes.filter((s) => {
      if (!this.#mayErase(s)) return false;
      for (let i = 1; i <= steps; i++) {
        const t = i / steps;
        if (strokeHit(s, prev[0] + (pt[0] - prev[0]) * t, prev[1] + (pt[1] - prev[1]) * t, r)) return true;
      }
      return false;
    });
    if (hits.length) {
      this.drawing.removed.push(...hits);
      this.#remove(page.id, hits.map((s) => s.id));
    }
    this.surface.queueLive();
  }

  // ---------------------------------------------------------------- lasso

  #finishLasso() {
    const poly = this.lasso;
    this.lasso = null;
    if (!poly || poly.length < 3) return this.surface.queueLive();
    const page = this.page;
    const ids = page.strokes.filter((s) => {
      if (!this.#mayErase(s)) return false;
      let inside = 0;
      for (const p of s.pts) if (pointInPoly(p, poly)) inside++;
      return inside >= Math.max(1, s.pts.length * 0.5);
    }).map((s) => s.id);
    if (!ids.length) return this.surface.queueLive();
    this.selection = { page: page.id, ids, drag: null };
    this.#updateSelection();
  }

  #selected() {
    return this.selection ? this.selection.ids.map((i) => this.idx.get(i)?.[0]).filter(Boolean) : [];
  }

  #box() {
    const ss = this.#selected();
    if (!ss.length) return null;
    const b = ss.map(strokeBounds).reduce((a, c) => [Math.min(a[0], c[0]), Math.min(a[1], c[1]), Math.max(a[2], c[2]), Math.max(a[3], c[3])]);
    const [dx, dy] = this.selection.drag || [0, 0];
    return [b[0] + dx - 6, b[1] + dy - 6, b[2] + dx + 6, b[3] + dy + 6];
  }

  #inBox(p) {
    const b = this.#box();
    return b && p[0] >= b[0] && p[0] <= b[2] && p[1] >= b[1] && p[1] <= b[3];
  }

  #replaceSelection(transform) {
    const page = this.nb.pages[this.selection.page];
    const old = this.#selected();
    if (!old.length || !page) return;
    const fresh = reid(old).map(transform);
    this.#remove(page.id, old.map((s) => s.id));
    this.#restore(page.id, fresh);
    this.#push({ page: page.id, removed: old, added: fresh });
    this.selection.ids = fresh.map((s) => s.id);
  }

  #finishMove() {
    const [dx, dy] = this.selection.drag || [0, 0];
    this.selection.drag = null;
    if (Math.abs(dx) + Math.abs(dy) > 0.5) {
      this.#replaceSelection((s) => ({ ...s, pts: s.pts.map(([x, y, p]) => [Math.round((x + dx) * 100) / 100, Math.round((y + dy) * 100) / 100, p]) }));
    }
    this.#updateSelection();
  }

  selectionAction(action, arg) {
    if (!this.selection) return;
    if (action === 'delete') {
      const old = this.#selected();
      this.#remove(this.selection.page, old.map((s) => s.id));
      this.#push({ page: this.selection.page, removed: old, added: [] });
      return this.clearSelection();
    }
    if (action === 'duplicate') {
      const page = this.nb.pages[this.selection.page];
      const copies = reid(this.#selected()).map((s) => ({ ...s, z: nextZ(), pts: s.pts.map(([x, y, p]) => [x + 24, y + 24, p]), ...(this.by ? { by: this.by } : {}) }));
      this.#restore(page.id, copies);
      this.#push({ page: page.id, removed: [], added: copies });
      this.selection.ids = copies.map((s) => s.id);
    }
    if (action === 'color') this.#replaceSelection((s) => ({ ...s, color: arg }));
    this.#updateSelection();
  }

  clearSelection() {
    if (!this.selection && !this.lasso) return;
    this.selection = null;
    this.lasso = null;
    this.#updateSelection();
  }

  #updateSelection() {
    const sel = this.selection;
    this.surface.hidden = new Set(sel?.drag ? sel.ids : []);
    this.surface.drawInk();
    this.surface.queueLive();
    const bar = this.selBar;
    const b = sel && this.#box();
    if (!b) return (bar.hidden = true);
    const v = this.surface.view;
    bar.hidden = false;
    const r = this.stage.getBoundingClientRect();
    bar.style.left = Math.max(8, Math.min(r.width - 220, v.x + b[0] * v.s)) + r.left + 'px';
    bar.style.top = Math.max(r.top + 8, v.y + b[1] * v.s + r.top - 52) + 'px';
  }

  #selectionBar() {
    const bar = document.createElement('div');
    bar.className = 'selbar';
    bar.hidden = true;
    const add = (label, fn) => {
      const b = document.createElement('button');
      b.textContent = label;
      b.onpointerdown = (e) => e.stopPropagation();
      b.onclick = (e) => {
        e.stopPropagation();
        fn();
      };
      bar.append(b);
    };
    add('Delete', () => this.selectionAction('delete'));
    add('Duplicate', () => this.selectionAction('duplicate'));
    add('Color', () => this.selectionAction('color', this.color));
    document.body.append(bar);
    this.selBar = bar;
  }

  // ---------------------------------------------------------------- overlay

  #overlay(ctx, k) {
    if (this.eraserAt) {
      ctx.strokeStyle = 'rgba(80,80,80,0.8)';
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.arc(this.eraserAt[0] * k, this.eraserAt[1] * k, this.eraserAt[2] * k, 0, Math.PI * 2);
      ctx.stroke();
    }
    const d = this.drawing;
    if (d?.kind === 'shape') drawPreview(ctx, d.stroke, k);
    if (this.lasso?.length > 1) {
      ctx.save();
      ctx.setLineDash([6, 5]);
      ctx.strokeStyle = 'rgba(40,110,230,0.9)';
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      this.lasso.forEach(([x, y], i) => (i ? ctx.lineTo(x * k, y * k) : ctx.moveTo(x * k, y * k)));
      ctx.stroke();
      ctx.restore();
    }
    if (this.selection) {
      const [dx, dy] = this.selection.drag || [0, 0];
      if (this.selection.drag) {
        for (const s of this.#selected()) drawPreview(ctx, { ...s, pts: s.pts.map(([x, y, p]) => [x + dx, y + dy, p]) }, k);
      }
      const b = this.#box();
      if (b) {
        ctx.save();
        ctx.setLineDash([5, 4]);
        ctx.strokeStyle = 'rgba(40,110,230,0.9)';
        ctx.lineWidth = 1.2;
        ctx.strokeRect(b[0] * k, b[1] * k, (b[2] - b[0]) * k, (b[3] - b[1]) * k);
        ctx.restore();
      }
      if (this.selection.drag) this.selBar.hidden = true;
    }
    this.extraOverlay?.(ctx, k);
  }

  // ---------------------------------------------------------------- zoom & pan

  #setZoomed(z) {
    this.zoomed = z;
    this.onzoom?.(z);
  }

  setView(s, x, y) {
    const p = this.page;
    const f = this.surface.fitScale(p, 12);
    s = Math.min(f * 10, Math.max(f * 0.5, s));
    const keep = 80;
    x = Math.min(this.surface.cw - keep, Math.max(keep - p.w * s, x));
    y = Math.min(this.surface.ch - keep, Math.max(keep - p.h * s, y));
    this.surface.view = { s, x, y };
    this.#setZoomed(true);
    this.#queueRedraw();
  }

  zoomAt(cx, cy, factor) {
    const v = this.surface.view;
    const s = v.s * factor;
    const f = this.surface.fitScale(this.page, 12);
    const clamped = Math.min(f * 10, Math.max(f * 0.5, s));
    const r = clamped / v.s;
    this.setView(clamped, cx - (cx - v.x) * r, cy - (cy - v.y) * r);
  }

  #queueRedraw() {
    if (this.viewQueued) return;
    this.viewQueued = true;
    requestAnimationFrame(() => {
      this.viewQueued = false;
      this.surface.redraw();
      if (this.selection) this.#updateSelection();
    });
  }

  #beginGesture() {
    const pts = [...this.touches.values()];
    this.gesture = { view: { ...this.surface.view }, c: centroid(pts), d: pts.length > 1 ? dist(pts[0], pts[1]) : 0, n: pts.length };
  }

  #moveGesture() {
    const pts = [...this.touches.values()];
    if (pts.length !== this.gesture.n) this.#beginGesture();
    const c = centroid(pts);
    const v0 = this.gesture.view;
    let s = v0.s;
    if (pts.length > 1) s = v0.s * (dist(pts[0], pts[1]) / this.gesture.d);
    const f = this.surface.fitScale(this.page, 12);
    s = Math.min(f * 10, Math.max(f * 0.5, s));
    const px = (this.gesture.c[0] - v0.x) / v0.s, py = (this.gesture.c[1] - v0.y) / v0.s;
    this.setView(s, c[0] - px * s, c[1] - py * s);
  }

  #local(e) {
    const r = this.stage.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }

  // ---------------------------------------------------------------- input

  #bind() {
    const st = this.stage;
    st.addEventListener('pointerdown', (e) => {
      if (!this.page || !this.surface.cw) return;
      this.onpointer?.();
      const mousePan = e.pointerType === 'mouse' && (e.button === 1 || this.space || !this.canDraw || this.tool === 'hand');
      if (mousePan) {
        this.pan = { id: e.pointerId, x: e.clientX, y: e.clientY, v: { ...this.surface.view } };
        this.#capture(e);
        document.body.classList.add('dragging');
        return;
      }
      const penLike = e.pointerType === 'pen' || (e.pointerType === 'mouse' && e.button === 0);
      if (penLike) {
        if (this.drawing || !this.canDraw) return;
        this.touches.clear();
        this.gesture = null;
        return this.#start(e);
      }
      if (e.pointerType !== 'touch') return;
      if (this.drawing && this.drawing.pointerType === 'pen') return; // palm while writing
      this.touches.set(e.pointerId, this.#local(e));
      if (this.settings.fingerDraw && this.canDraw && this.touches.size === 1 && !this.drawing) return this.#start(e);
      if (this.drawing && this.drawing.pointerType === 'touch') this.#end(true); // second finger: a gesture
      this.#capture(e);
      this.#beginGesture();
    });
    st.addEventListener('pointermove', (e) => {
      if (this.pan && e.pointerId === this.pan.id) {
        const { v } = this.pan;
        return this.setView(v.s, v.x + e.clientX - this.pan.x, v.y + e.clientY - this.pan.y);
      }
      if (this.drawing && e.pointerId === this.drawing.pointerId) {
        if (e.pointerType === 'touch') this.touches.set(e.pointerId, this.#local(e));
        return this.#move(e);
      }
      if (this.touches.has(e.pointerId)) {
        this.touches.set(e.pointerId, this.#local(e));
        if (this.gesture) this.#moveGesture();
        return;
      }
      // Pencil hover (iPad Pro) or mouse hover: a cursor on the share window.
      if ((e.pointerType === 'pen' || e.pointerType === 'mouse') && e.buttons === 0 && this.page && this.oncursor) {
        const [x, y] = this.#point(e);
        if (!this.hoverQueued) {
          requestAnimationFrame(() => {
            this.oncursor({ page: this.pid, x: this.hoverQueued[0], y: this.hoverQueued[1] });
            this.hoverQueued = null;
          });
        }
        this.hoverQueued = [x, y];
      }
    });
    const end = (e) => {
      if (this.pan && e.pointerId === this.pan.id) {
        this.pan = null;
        document.body.classList.remove('dragging');
        return;
      }
      if (this.drawing && e.pointerId === this.drawing.pointerId) {
        this.touches.delete(e.pointerId);
        this.#end(e.type === 'pointercancel' && this.drawing.pointerType === 'touch');
        return;
      }
      if (this.touches.delete(e.pointerId)) {
        if (this.touches.size) this.#beginGesture();
        else this.gesture = null;
      }
    };
    st.addEventListener('pointerup', end);
    st.addEventListener('pointercancel', end);
    st.addEventListener('pointerleave', (e) => {
      if (e.pointerType !== 'touch' && !this.drawing) this.oncursor?.({ hide: true });
    });
    // Mouse wheel zooms at the pointer; a touchpad's two-finger scroll pans
    // and its pinch (reported as ctrl+wheel) zooms.
    st.addEventListener('wheel', (e) => {
      e.preventDefault();
      if (!this.page) return;
      const r = st.getBoundingClientRect();
      const cx = e.clientX - r.left, cy = e.clientY - r.top;
      const lines = e.deltaMode === 1;
      const mouseWheel = lines || (e.deltaX === 0 && Math.abs(e.deltaY) >= 40 && Number.isInteger(e.deltaY));
      if (e.ctrlKey) this.zoomAt(cx, cy, Math.exp(-e.deltaY * 0.01));
      else if (mouseWheel && this.page.h / this.page.w <= 1.05) {
        const notches = Math.min(4, Math.max(1, Math.abs(e.deltaY) / (lines ? 3 : 100)));
        this.zoomAt(cx, cy, Math.pow(e.deltaY < 0 ? 1.18 : 1 / 1.18, notches));
      } else {
        const v = this.surface.view;
        this.setView(v.s, v.x - e.deltaX * (lines ? 30 : 1), v.y - e.deltaY * (lines ? 30 : 1));
      }
    }, { passive: false });
    // Keep iOS from scrolling, zooming, or popping the magnifier.
    for (const ev of ['touchstart', 'touchmove', 'gesturestart', 'gesturechange'])
      st.addEventListener(ev, (e) => e.preventDefault(), { passive: false });
    document.addEventListener('keydown', (e) => {
      if (e.key === ' ' && e.target === document.body) this.space = true;
    });
    document.addEventListener('keyup', (e) => {
      if (e.key === ' ') this.space = false;
    });
  }

  layout() {
    this.surface.resize();
    if (this.page) {
      if (!this.zoomed) this.fit();
      this.surface.setPage(this.page);
    }
  }
}

// ---------------------------------------------------------------- shapes

const N = NEUTRAL_PRESSURE;

function line(a, b) {
  const n = Math.max(2, Math.ceil(Math.hypot(b[0] - a[0], b[1] - a[1]) / 12));
  const out = [];
  for (let i = 0; i <= n; i++) out.push([a[0] + ((b[0] - a[0]) * i) / n, a[1] + ((b[1] - a[1]) * i) / n, N].map((v, j) => (j < 2 ? Math.round(v * 100) / 100 : v)));
  return out;
}

// Shapes are ordinary strokes, so they sync, erase and export like ink.
// Shapes with corners are drawn as separate pen-up segments joined in one
// stroke by repeating the corner point.
export function shapePoints(kind, a, b) {
  const [x0, y0] = a, [x1, y1] = b;
  const r2 = (v) => Math.round(v * 100) / 100;
  const P = (x, y) => [r2(x), r2(y), N];
  if (kind === 'line') return line(a, b);
  if (kind === 'arrow') {
    const ang = Math.atan2(y1 - y0, x1 - x0);
    const len = Math.min(28, Math.hypot(x1 - x0, y1 - y0) * 0.35);
    const h1 = P(x1 - len * Math.cos(ang - 0.45), y1 - len * Math.sin(ang - 0.45));
    const h2 = P(x1 - len * Math.cos(ang + 0.45), y1 - len * Math.sin(ang + 0.45));
    return [...line(a, b), h1, P(x1, y1), h2];
  }
  if (kind === 'rect') return [P(x0, y0), P(x1, y0), P(x1, y0), P(x1, y1), P(x1, y1), P(x0, y1), P(x0, y1), P(x0, y0), P(x0, y0)];
  if (kind === 'ellipse') {
    const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, rx = Math.abs(x1 - x0) / 2, ry = Math.abs(y1 - y0) / 2;
    const n = Math.max(24, Math.min(96, Math.round((rx + ry) / 3)));
    const out = [];
    for (let i = 0; i <= n + 1; i++) out.push(P(cx + rx * Math.cos((i / n) * Math.PI * 2), cy + ry * Math.sin((i / n) * Math.PI * 2)));
    return out;
  }
  if (kind === 'axes') {
    // x and y axes crossing at the start point, with arrowheads.
    const ex = x1, ey = y1;
    const dx = Math.sign(ex - x0) || 1, dy = Math.sign(ey - y0) || -1;
    const ah = 12;
    const xa = [P(x0 - 20 * dx, y0), P(ex, y0), P(ex - ah * dx, y0 - ah * 0.6), P(ex, y0), P(ex - ah * dx, y0 + ah * 0.6), P(ex, y0)];
    const ya = [P(x0, y0), P(x0, y0 - 20 * dy), P(x0, y0), P(x0, ey), P(x0 - ah * 0.6, ey - ah * dy), P(x0, ey), P(x0 + ah * 0.6, ey - ah * dy)];
    return [...xa, ...ya];
  }
  return line(a, b);
}

function drawPreview(ctx, s, k) {
  ctx.save();
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.strokeStyle = s.color;
  ctx.lineWidth = s.width * k;
  if (s.tool === 'hl') ctx.globalAlpha = 0.32;
  ctx.beginPath();
  s.pts.forEach(([x, y], i) => (i ? ctx.lineTo(x * k, y * k) : ctx.moveTo(x * k, y * k)));
  ctx.stroke();
  ctx.restore();
}

function pointInPoly([x, y], poly) {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [xi, yi] = poly[i], [xj, yj] = poly[j];
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

const centroid = (pts) => pts.reduce((a, p) => [a[0] + p.x / pts.length, a[1] + p.y / pts.length], [0, 0]);
const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y) || 1;
