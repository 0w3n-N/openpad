// Drawing, page backgrounds (PDFs via pdf.js) and PDF export, shared by the
// notes app, the share window and guest pages.

export const COLORS = ['#111111', '#1f5fd6', '#d62f2f', '#1d9a4b', '#e07b00', '#7b3fd1', '#ffffff'];

// ---------------------------------------------------------------- pressure

// Width multiplier from the stored pressure value. Points are stored already
// shaped by the writer's sensitivity setting (see shapePressure), so every
// screen draws the same widths.
export const pressureWidth = (base, p) => base * (0.35 + 1.15 * Math.min(1, Math.max(0, p ?? 0.5)));
const NEUTRAL = 0.65 / 1.15; // stored value that gives exactly the base width

// Raw Pencil pressure -> stored value. sensitivity 0 = constant width,
// 1 = the full range. Values are smoothed along the stroke so small wobbles
// in pressure don't make the line lumpy.
export function shapePressure(raw, sensitivity, prev) {
  const p = NEUTRAL + (Math.min(1, Math.max(0, raw)) - NEUTRAL) * sensitivity;
  return prev == null ? p : prev + (p - prev) * 0.35;
}
export { NEUTRAL as NEUTRAL_PRESSURE };

// ---------------------------------------------------------------- strokes

// Quadratic segments through midpoints, one per point so width follows pressure.
function segments(p) {
  const out = [];
  let x0 = p[0][0], y0 = p[0][1];
  for (let i = 1; i < p.length; i++) {
    const last = i === p.length - 1;
    const x1 = last ? p[i][0] : (p[i][0] + p[i + 1][0]) / 2;
    const y1 = last ? p[i][1] : (p[i][1] + p[i + 1][1]) / 2;
    out.push({ x0, y0, cx: p[i][0], cy: p[i][1], x1, y1, line: last, pr: p[i][2] });
    x0 = x1;
    y0 = y1;
  }
  return out;
}

export function drawStroke(ctx, s, k) {
  const p = s.pts;
  if (!p || !p.length) return;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.strokeStyle = s.color;
  ctx.fillStyle = s.color;
  if (s.tool === 'hl') {
    ctx.save();
    ctx.globalAlpha = 0.32;
    ctx.globalCompositeOperation = 'multiply';
    ctx.lineWidth = s.width * k;
    ctx.beginPath();
    ctx.moveTo(p[0][0] * k, p[0][1] * k);
    for (const g of segments(p)) {
      if (g.line) ctx.lineTo(g.x1 * k, g.y1 * k);
      else ctx.quadraticCurveTo(g.cx * k, g.cy * k, g.x1 * k, g.y1 * k);
    }
    if (p.length === 1) ctx.lineTo(p[0][0] * k + 0.01, p[0][1] * k);
    ctx.stroke();
    ctx.restore();
    return;
  }
  if (p.length === 1) {
    ctx.beginPath();
    ctx.arc(p[0][0] * k, p[0][1] * k, Math.max(0.1, (pressureWidth(s.width, p[0][2]) * k) / 2), 0, Math.PI * 2);
    ctx.fill();
    return;
  }
  for (const g of segments(p)) {
    ctx.lineWidth = pressureWidth(s.width, g.pr) * k;
    ctx.beginPath();
    ctx.moveTo(g.x0 * k, g.y0 * k);
    if (g.line) ctx.lineTo(g.x1 * k, g.y1 * k);
    else ctx.quadraticCurveTo(g.cx * k, g.cy * k, g.x1 * k, g.y1 * k);
    ctx.stroke();
  }
}

function segDist2(px, py, ax, ay, bx, by) {
  const dx = bx - ax, dy = by - ay;
  const l2 = dx * dx + dy * dy;
  let t = l2 ? ((px - ax) * dx + (py - ay) * dy) / l2 : 0;
  t = Math.max(0, Math.min(1, t));
  const x = ax + t * dx - px, y = ay + t * dy - py;
  return x * x + y * y;
}

export function strokeHit(s, x, y, r) {
  const p = s.pts;
  const rr = r + (s.width || 0) / 2;
  const r2 = rr * rr;
  if (p.length === 1) return (p[0][0] - x) ** 2 + (p[0][1] - y) ** 2 <= r2;
  for (let i = 1; i < p.length; i++) {
    if (segDist2(x, y, p[i - 1][0], p[i - 1][1], p[i][0], p[i][1]) <= r2) return true;
  }
  return false;
}

export function strokeBounds(s) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const [x, y] of s.pts) {
    x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y);
  }
  const m = s.width;
  return [x0 - m, y0 - m, x1 + m, y1 + m];
}

// ---------------------------------------------------------------- paper

// Paper lines as [x0, y0, x1, y1, color, width] in page units, shared by the
// screen and PDF export.
export function paperLines(page) {
  const kind = page.paper || 'blank';
  const out = [];
  if (kind === 'blank' || page.bg || kind === 'dots') return out;
  const { w, h } = page;
  if (kind === 'lines') {
    for (let y = 64; y < h - 8; y += 32) out.push([0, y, w, y, '#c8d6ea', 1]);
    out.push([80, 0, 80, h, '#f0b4b4', 1]);
  } else if (kind === 'grid') {
    for (let y = 32; y < h; y += 32) out.push([0, y, w, y, '#dbe2ec', 1]);
    for (let x = 32; x < w; x += 32) out.push([x, 0, x, h, '#dbe2ec', 1]);
  } else if (kind === 'eng') {
    // Engineering paper: fine 10-unit grid with a darker line every 5 cells.
    for (let y = 10, i = 1; y < h; y += 10, i++) out.push([0, y, w, y, i % 5 ? '#e3eaf2' : '#b7c7da', i % 5 ? 0.6 : 1]);
    for (let x = 10, i = 1; x < w; x += 10, i++) out.push([x, 0, x, h, i % 5 ? '#e3eaf2' : '#b7c7da', i % 5 ? 0.6 : 1]);
  }
  return out;
}

export function drawPaper(ctx, page, k) {
  const w = page.w * k, h = page.h * k;
  ctx.fillStyle = page.bg?.live ? '#000000' : '#ffffff';
  ctx.fillRect(0, 0, w, h);
  if (page.bg) return;
  if (page.paper === 'dots') {
    ctx.fillStyle = '#b9c0cc';
    const r = Math.max(1, 1.6 * k);
    for (let y = 32; y < page.h; y += 32)
      for (let x = 32; x < page.w; x += 32) {
        ctx.beginPath();
        ctx.arc(x * k, y * k, r, 0, Math.PI * 2);
        ctx.fill();
      }
    return;
  }
  for (const [x0, y0, x1, y1, color, lw] of paperLines(page)) {
    ctx.strokeStyle = color;
    ctx.lineWidth = Math.max(0.6, lw * k);
    ctx.beginPath();
    const vx = x0 === x1, px = (v) => Math.round(v * k) + 0.5;
    ctx.moveTo(vx ? px(x0) : x0 * k, vx ? y0 * k : px(y0));
    ctx.lineTo(vx ? px(x1) : x1 * k, vx ? y1 * k : px(y1));
    ctx.stroke();
  }
}

// ---------------------------------------------------------------- backgrounds

let pdfjsReady = null;
function pdfjs() {
  pdfjsReady ??= import(new URL('./vendor/pdfjs/pdf.min.mjs', import.meta.url).href).then((lib) => {
    lib.GlobalWorkerOptions.workerSrc = new URL('./vendor/pdfjs/pdf.worker.min.mjs', import.meta.url).href;
    return lib;
  });
  return pdfjsReady;
}

// Page count and page sizes (points, rotation applied) of a PDF.
export async function pdfInfo(bytes) {
  const lib = await pdfjs();
  const doc = await lib.getDocument({ data: bytes.slice(0), isEvalSupported: false, disableFontFace: false }).promise;
  const sizes = [];
  for (let i = 1; i <= Math.min(doc.numPages, 2000); i++) {
    const vp = (await doc.getPage(i)).getViewport({ scale: 1 });
    sizes.push([Math.round(vp.width * 100) / 100, Math.round(vp.height * 100) / 100]);
  }
  doc.destroy();
  return sizes;
}

const WIDTHS = [800, 1400, 2000, 2600];
const PIXEL_BUDGET = 40e6; // about 160 MB of canvas memory for PDF pages
// Safari only frees a canvas's memory once it has no size.
const free = (c) => {
  c.width = 0;
  c.height = 0;
};

// Rendered PDF pages and images for page backgrounds. `source(sha)` returns
// the file's bytes (ArrayBuffer) or a URL to fetch it from.
export class Backgrounds {
  constructor(source) {
    this.source = source;
    this.docs = new Map(); // sha -> Promise<PDFDocumentProxy>
    this.images = new Map(); // sha -> {bmp, waiters}
    this.renders = new Map(); // `${sha}/${n}/${px}` -> {canvas, waiters}
    this.order = [];
    this.pixels = 0; // in rendered canvases: iPad Safari crashes a tab past ~384 MB
  }
  async #bytes(sha) {
    const src = await this.source(sha);
    if (typeof src === 'string') {
      const r = await fetch(src);
      if (!r.ok) throw new Error(`could not load ${sha.slice(0, 8)} (${r.status})`);
      return new Uint8Array(await r.arrayBuffer());
    }
    return new Uint8Array(src);
  }
  #doc(sha) {
    if (!this.docs.has(sha)) {
      const p = (async () => {
        const lib = await pdfjs();
        return lib.getDocument({ data: await this.#bytes(sha), isEvalSupported: false }).promise;
      })();
      p.catch(() => this.docs.delete(sha));
      this.docs.set(sha, p);
    }
    return this.docs.get(sha);
  }
  // The drawable for a page at about `px` pixels wide, or null while it loads
  // (onready runs when it's there).
  get(page, px, onready) {
    const bg = page.bg;
    if (!bg) return null;
    if (bg.img) {
      let e = this.images.get(bg.img);
      if (!e) {
        e = { bmp: null, waiters: [] };
        this.images.set(bg.img, e);
        this.#bytes(bg.img)
          .then((b) => createImageBitmap(new Blob([b])))
          .then((bmp) => {
            e.bmp = bmp;
            e.waiters.splice(0).forEach((f) => f());
          })
          .catch(() => this.images.delete(bg.img));
      }
      if (!e.bmp && onready) e.waiters.push(onready);
      return e.bmp;
    }
    if (!bg.pdf) return null;
    // Render at a few fixed widths so zooming doesn't re-render constantly.
    const want = WIDTHS.find((w) => w >= px) || WIDTHS[WIDTHS.length - 1];
    const key = `${bg.pdf}/${bg.n}/${want}`;
    let e = this.renders.get(key);
    if (e) {
      this.order.splice(this.order.indexOf(key), 1);
      this.order.push(key); // most recently used last
    } else {
      e = { canvas: null, waiters: [] };
      this.renders.set(key, e);
      this.order.push(key);
      this.#render(bg.pdf, bg.n, want)
        .then((c) => {
          if (this.renders.get(key) !== e) return free(c); // evicted meanwhile
          e.canvas = c;
          this.pixels += c.width * c.height;
          this.#evict(key);
          e.waiters.splice(0).forEach((f) => f());
        })
        .catch(() => {
          this.renders.delete(key);
          this.order.splice(this.order.indexOf(key), 1);
        });
    }
    if (!e.canvas) {
      if (onready) e.waiters.push(onready);
      // Meanwhile, any rendered size of the same page will do.
      for (const w of [...WIDTHS].reverse()) {
        const other = this.renders.get(`${bg.pdf}/${bg.n}/${w}`);
        if (other?.canvas) return other.canvas;
      }
    }
    return e.canvas;
  }
  // Drop the least recently used renders over the budget (never `keep`).
  #evict(keep) {
    for (let i = 0; this.pixels > PIXEL_BUDGET && i < this.order.length; ) {
      const key = this.order[i];
      const e = this.renders.get(key);
      if (key === keep || !e?.canvas) {
        i++;
        continue;
      }
      this.pixels -= e.canvas.width * e.canvas.height;
      free(e.canvas);
      this.renders.delete(key);
      this.order.splice(i, 1);
    }
  }
  async #render(sha, n, width) {
    const doc = await this.#doc(sha);
    const page = await doc.getPage(n);
    const vp1 = page.getViewport({ scale: 1 });
    const vp = page.getViewport({ scale: width / vp1.width });
    const c = document.createElement('canvas');
    c.width = Math.round(vp.width);
    c.height = Math.round(vp.height);
    const ctx = c.getContext('2d');
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, c.width, c.height);
    await page.render({ canvasContext: ctx, viewport: vp }).promise;
    return c;
  }
  // Wait for a background (for export).
  async load(page, px) {
    for (let i = 0; i < 400; i++) {
      const d = this.get(page, px);
      if (d && (!page.bg?.pdf || d.width >= Math.min(px, WIDTHS[WIDTHS.length - 1]) * 0.99 || i > 300)) return d;
      await new Promise((r) => setTimeout(r, 25));
    }
    return this.get(page, px);
  }
}

// ---------------------------------------------------------------- surface

// Stacked canvases: paper/PDF, live window video, committed ink, and
// in-progress strokes.
export class Surface {
  constructor(root, backgrounds) {
    this.root = root;
    this.backgrounds = backgrounds;
    this.bg = this.#canvas();
    this.media = this.#canvas();
    this.ink = this.#canvas();
    this.live = this.#canvas();
    this.page = null;
    this.active = new Map(); // stroke id -> stroke still being drawn
    this.hidden = new Set(); // stroke ids not drawn on the ink layer (e.g. being moved)
    this.view = { s: 1, x: 0, y: 0 }; // page unit -> css px
    this.dpr = 1;
    this.cw = 0;
    this.ch = 0;
    this.liveQueued = false;
    this.frame = null; // latest live-window frame (ImageBitmap)
    this.decoding = false;
    this.nextBlob = null;
    this.mediaQueued = false;
  }
  #canvas() {
    const c = document.createElement('canvas');
    this.root.appendChild(c);
    return c;
  }
  resize() {
    this.dpr = window.devicePixelRatio || 1;
    const r = this.root.getBoundingClientRect();
    this.cw = r.width;
    this.ch = r.height;
    for (const c of [this.bg, this.media, this.ink, this.live]) {
      c.width = Math.round(r.width * this.dpr);
      c.height = Math.round(r.height * this.dpr);
      c.style.width = r.width + 'px';
      c.style.height = r.height + 'px';
    }
  }
  fitScale(page = this.page, margin = 16) {
    return page ? Math.max(0.01, Math.min((this.cw - margin * 2) / page.w, (this.ch - margin * 2) / page.h)) : 1;
  }
  fit(page = this.page, margin = 16) {
    if (!page) return;
    const s = this.fitScale(page, margin);
    this.view = { s, x: (this.cw - page.w * s) / 2, y: (this.ch - page.h * s) / 2 };
  }
  // Fit the page width and start at its top (portrait notes pages).
  fitWidth(page = this.page, margin = 16) {
    if (!page) return;
    const s = Math.max(0.01, Math.min((this.cw - margin * 2) / page.w, ((this.ch - margin * 2) / page.h) * 3));
    this.view = { s, x: (this.cw - page.w * s) / 2, y: margin };
    if (page.h * s < this.ch - margin * 2) this.view.y = (this.ch - page.h * s) / 2;
  }
  toPage(cx, cy) {
    return [(cx - this.view.x) / this.view.s, (cy - this.view.y) / this.view.s];
  }
  #prep(c) {
    const ctx = c.getContext('2d');
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, c.width, c.height);
    ctx.setTransform(this.dpr, 0, 0, this.dpr, this.view.x * this.dpr, this.view.y * this.dpr);
    return ctx;
  }
  setPage(page) {
    if (page !== this.page) {
      this.frameFor = null;
    }
    this.page = page;
    this.redraw();
  }
  redraw() {
    this.drawBg();
    this.drawMedia();
    this.drawInk();
    this.drawLive();
  }
  // A new JPEG frame of the live window. If decoding falls behind, only the
  // newest frame is kept.
  pushFrame(blob) {
    if (this.decoding) {
      this.nextBlob = blob;
      return;
    }
    this.decoding = true;
    createImageBitmap(blob)
      .then((bmp) => {
        this.frame?.close?.();
        this.frame = bmp;
        this.queueMedia();
      })
      .catch(() => {})
      .finally(() => {
        this.decoding = false;
        const next = this.nextBlob;
        this.nextBlob = null;
        if (next) this.pushFrame(next);
      });
  }
  queueMedia() {
    if (this.mediaQueued) return;
    this.mediaQueued = true;
    requestAnimationFrame(() => {
      this.mediaQueued = false;
      this.drawMedia();
    });
  }
  drawMedia() {
    const ctx = this.#prep(this.media);
    const page = this.page;
    if (!page?.bg?.live || !this.frame) return;
    const k = this.view.s;
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(this.frame, 0, 0, page.w * k, page.h * k);
  }
  drawBg() {
    const page = this.page;
    const ctx = this.#prep(this.bg);
    if (!page) return;
    const k = this.view.s;
    ctx.shadowColor = 'rgba(0,0,0,0.35)';
    ctx.shadowBlur = 18;
    ctx.fillStyle = page.bg?.live ? '#000' : '#fff';
    ctx.fillRect(0, 0, page.w * k, page.h * k);
    ctx.shadowColor = 'transparent';
    drawPaper(ctx, page, k);
    const img = this.backgrounds?.get(page, page.w * k * this.dpr, () => this.page === page && this.drawBg());
    if (img?.width) {
      ctx.imageSmoothingQuality = 'high';
      ctx.drawImage(img, 0, 0, page.w * k, page.h * k);
    }
  }
  drawInk() {
    const ctx = this.#prep(this.ink);
    if (!this.page) return;
    for (const s of this.page.strokes) if (!this.active.has(s.id) && !this.hidden.has(s.id)) drawStroke(ctx, s, this.view.s);
  }
  commit(s) {
    this.active.delete(s.id);
    const ctx = this.ink.getContext('2d');
    ctx.setTransform(this.dpr, 0, 0, this.dpr, this.view.x * this.dpr, this.view.y * this.dpr);
    drawStroke(ctx, s, this.view.s);
    this.queueLive();
  }
  queueLive() {
    if (this.liveQueued) return;
    this.liveQueued = true;
    requestAnimationFrame(() => {
      this.liveQueued = false;
      this.drawLive();
    });
  }
  drawLive() {
    const ctx = this.#prep(this.live);
    for (const s of this.active.values()) drawStroke(ctx, s, this.view.s);
    this.overlay?.(ctx, this.view.s);
  }
}

// ---------------------------------------------------------------- PDF export

const f2 = (v) => (Math.round(v * 100) / 100).toString();

function pdfString(text) {
  if (/^[\x20-\x7e]*$/.test(text)) return '(' + text.replace(/[\\()]/g, (c) => '\\' + c) + ')';
  let hex = 'FEFF';
  for (const ch of text) {
    const cp = ch.codePointAt(0);
    const units = cp > 0xffff ? [0xd800 + ((cp - 0x10000) >> 10), 0xdc00 + ((cp - 0x10000) & 0x3ff)] : [cp];
    for (const u of units) hex += u.toString(16).padStart(4, '0').toUpperCase();
  }
  return `<${hex}>`;
}

function rgb(hex) {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((v) => f2(v / 255)).join(' ');
}

// Ink as PDF path operators, in page units (the page's `cm` maps them).
function inkOps(page) {
  const out = ['1 J 1 j'];
  for (const s of page.strokes) {
    const p = s.pts;
    if (!p?.length) continue;
    const c = rgb(s.color);
    if (s.tool === 'hl') {
      out.push(`q /HL gs ${c} RG ${f2(s.width)} w ${f2(p[0][0])} ${f2(p[0][1])} m`);
      for (const g of segments(p)) {
        if (g.line) out.push(`${f2(g.x1)} ${f2(g.y1)} l`);
        else out.push(cubic(g));
      }
      if (p.length === 1) out.push(`${f2(p[0][0] + 0.01)} ${f2(p[0][1])} l`);
      out.push('S Q');
      continue;
    }
    if (p.length === 1) {
      const r = pressureWidth(s.width, p[0][2]) / 2;
      out.push(`${c} rg ${circle(p[0][0], p[0][1], r)} f`);
      continue;
    }
    out.push(`${c} RG`);
    let lastW = null;
    for (const g of segments(p)) {
      const w = f2(pressureWidth(s.width, g.pr));
      if (w !== lastW) out.push(`${w} w`);
      lastW = w;
      out.push(`${f2(g.x0)} ${f2(g.y0)} m ${g.line ? `${f2(g.x1)} ${f2(g.y1)} l` : cubic(g)} S`);
    }
  }
  return out.join('\n');
}

function cubic(g) {
  const c1x = g.x0 + (2 / 3) * (g.cx - g.x0), c1y = g.y0 + (2 / 3) * (g.cy - g.y0);
  const c2x = g.x1 + (2 / 3) * (g.cx - g.x1), c2y = g.y1 + (2 / 3) * (g.cy - g.y1);
  return `${f2(c1x)} ${f2(c1y)} ${f2(c2x)} ${f2(c2y)} ${f2(g.x1)} ${f2(g.y1)} c`;
}

function circle(x, y, r) {
  const k = 0.5523 * r;
  return `${f2(x + r)} ${f2(y)} m ${f2(x + r)} ${f2(y + k)} ${f2(x + k)} ${f2(y + r)} ${f2(x)} ${f2(y + r)} c ` +
    `${f2(x - k)} ${f2(y + r)} ${f2(x - r)} ${f2(y + k)} ${f2(x - r)} ${f2(y)} c ` +
    `${f2(x - r)} ${f2(y - k)} ${f2(x - k)} ${f2(y - r)} ${f2(x)} ${f2(y - r)} c ` +
    `${f2(x + k)} ${f2(y - r)} ${f2(x + r)} ${f2(y - k)} ${f2(x + r)} ${f2(y)} c`;
}

function paperOps(page) {
  if (page.bg) return '';
  if (page.paper === 'dots') {
    const out = ['0.725 0.753 0.8 rg'];
    for (let y = 32; y < page.h; y += 32) for (let x = 32; x < page.w; x += 32) out.push(`${circle(x, y, 1.6)} f`);
    return out.join('\n');
  }
  return paperLines(page).map(([x0, y0, x1, y1, color, lw]) =>
    `${rgb(color)} RG ${f2(lw)} w ${f2(x0)} ${f2(y0)} m ${f2(x1)} ${f2(y1)} l S`).join('\n');
}

async function deflate(bytes) {
  if (typeof CompressionStream === 'undefined') return null;
  const stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream('deflate'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

async function jpegOf(drawable, maxW = 2000) {
  const k = Math.min(1, maxW / drawable.width);
  const c = document.createElement('canvas');
  c.width = Math.max(1, Math.round(drawable.width * k));
  c.height = Math.max(1, Math.round(drawable.height * k));
  const ctx = c.getContext('2d');
  ctx.fillStyle = '#fff';
  ctx.fillRect(0, 0, c.width, c.height);
  ctx.drawImage(drawable, 0, 0, c.width, c.height);
  const blob = await new Promise((res) => c.toBlob(res, 'image/jpeg', 0.86));
  const out = { bytes: new Uint8Array(await blob.arrayBuffer()), w: c.width, h: c.height };
  free(c);
  return out;
}

// Build a PDF of `pages`. Ink and paper are vectors; PDF and window
// backgrounds are embedded as images. `outline` is [{title, index}] bookmarks.
// `liveFrame` is the current frame of a live window, if one is on the pages.
export async function buildPDF(pages, { backgrounds, outline = [], title = 'OpenPad', liveFrame = null, onprogress } = {}) {
  const enc = new TextEncoder();
  const chunks = [];
  const offsets = [];
  let pos = 0;
  const put = (x) => {
    const b = typeof x === 'string' ? enc.encode(x) : x;
    chunks.push(b);
    pos += b.length;
  };
  let next = 1;
  const alloc = () => next++;
  const CATALOG = alloc(), PAGES = alloc(), GS = alloc(), INFO = alloc();
  const OUTLINES = outline.length ? alloc() : 0;
  const pageIds = pages.map(() => alloc());
  const obj = (id, body) => {
    offsets[id] = pos;
    put(`${id} 0 obj\n${body}\nendobj\n`);
  };
  const stream = async (id, dict, data) => {
    const raw = typeof data === 'string' ? enc.encode(data) : data;
    const z = dict.includes('/Filter') ? null : await deflate(raw);
    offsets[id] = pos;
    put(`${id} 0 obj\n<< ${dict}${z ? ' /Filter /FlateDecode' : ''} /Length ${(z || raw).length} >>\nstream\n`);
    put(z || raw);
    put('\nendstream\nendobj\n');
  };
  put('%PDF-1.5\n%\xC7\xEC\x8F\xA2\n');
  obj(CATALOG, `<< /Type /Catalog /Pages ${PAGES} 0 R${OUTLINES ? ` /Outlines ${OUTLINES} 0 R /PageMode /UseOutlines` : ''} >>`);
  obj(PAGES, `<< /Type /Pages /Count ${pages.length} /Kids [${pageIds.map((i) => `${i} 0 R`).join(' ')}] >>`);
  obj(GS, '<< /Type /ExtGState /CA 0.32 /ca 0.32 /BM /Multiply >>');
  obj(INFO, `<< /Title ${pdfString(title)} /Producer (OpenPad) >>`);
  for (let i = 0; i < pages.length; i++) {
    const page = pages[i];
    onprogress?.(i, pages.length);
    const [W, H] = page.pt || [612, 612 * (page.h / page.w)];
    const k = W / page.w;
    const contentId = alloc();
    let image = null;
    if (page.bg) {
      let d = null;
      if (page.bg.live) d = liveFrame;
      else if (backgrounds) {
        d = await backgrounds.load(page, 1700);
        if (d && !d.width) d = await backgrounds.load(page, 1700); // freed meanwhile to save memory
      }
      if (d?.width) image = { id: alloc(), ...(await jpegOf(d)) };
    }
    const content = [
      `q ${f2(k)} 0 0 ${f2(-k)} 0 ${f2(H)} cm`,
      page.bg?.live ? `0 0 0 rg 0 0 ${f2(page.w)} ${f2(page.h)} re f` : '',
      image ? `q ${f2(page.w)} 0 0 ${f2(-page.h)} 0 ${f2(page.h)} cm /Im0 Do Q` : paperOps(page),
      inkOps(page),
      'Q',
    ].join('\n');
    obj(pageIds[i], `<< /Type /Page /Parent ${PAGES} 0 R /MediaBox [0 0 ${f2(W)} ${f2(H)}] ` +
      `/Resources << /ExtGState << /HL ${GS} 0 R >>${image ? ` /XObject << /Im0 ${image.id} 0 R >>` : ''} >> ` +
      `/Contents ${contentId} 0 R >>`);
    await stream(contentId, '', content);
    if (image) {
      await stream(image.id, `/Type /XObject /Subtype /Image /Width ${image.w} /Height ${image.h} ` +
        '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode', image.bytes);
    }
  }
  if (OUTLINES) {
    const items = outline.map(() => alloc());
    obj(OUTLINES, `<< /Type /Outlines /First ${items[0]} 0 R /Last ${items[items.length - 1]} 0 R /Count ${items.length} >>`);
    outline.forEach((o, i) => {
      const H = (pages[o.index]?.pt || [0, 792])[1];
      obj(items[i], `<< /Title ${pdfString(o.title)} /Parent ${OUTLINES} 0 R` +
        (i ? ` /Prev ${items[i - 1]} 0 R` : '') + (i < items.length - 1 ? ` /Next ${items[i + 1]} 0 R` : '') +
        ` /Dest [${pageIds[o.index]} 0 R /XYZ 0 ${f2(H)} 0] >>`);
    });
  }
  const count = next;
  const xref = pos;
  let x = `xref\n0 ${count}\n0000000000 65535 f \n`;
  for (let i = 1; i < count; i++) x += `${String(offsets[i]).padStart(10, '0')} 00000 n \n`;
  put(x);
  put(`trailer\n<< /Size ${count} /Root ${CATALOG} 0 R /Info ${INFO} 0 R >>\nstartxref\n${xref}\n%%EOF\n`);
  return new Blob(chunks, { type: 'application/pdf' });
}

// Let the person choose where the PDF goes: a save dialog (Chrome, Edge), the
// share sheet (iPad: "Save to Files" picks any folder), or a plain download.
export async function savePDF(blob, filename) {
  if (window.showSaveFilePicker) {
    try {
      const handle = await window.showSaveFilePicker({
        suggestedName: filename,
        types: [{ description: 'PDF', accept: { 'application/pdf': ['.pdf'] } }],
      });
      const w = await handle.createWritable();
      await w.write(blob);
      await w.close();
      return 'saved';
    } catch (e) {
      if (e.name === 'AbortError') return 'cancelled';
    }
  }
  const file = new File([blob], filename, { type: 'application/pdf' });
  const touch = navigator.maxTouchPoints > 1;
  if (touch && navigator.canShare?.({ files: [file] })) {
    try {
      await navigator.share({ files: [file] });
      return 'shared';
    } catch (e) {
      if (e.name === 'AbortError') return 'cancelled';
    }
  }
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => {
    URL.revokeObjectURL(a.href);
    a.remove();
  }, 10000);
  return 'downloaded';
}

export function pdfName(title) {
  const clean = (title || 'notes').replace(/[\\/:*?"<>|\x00-\x1f]/g, '').trim().slice(0, 80) || 'notes';
  return `${clean}.pdf`;
}
