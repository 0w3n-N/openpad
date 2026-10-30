// Notebooks: the same merge rules as openpad/notebook.py (read that file's
// docstring first). Strokes are only ever added or removed ("gone"), page
// settings and the section layout are last-writer-wins by timestamp, and
// deleted pages stay deleted. tests/run.py checks both sides agree.

export const PAGE_W = 1000;
export const SIZES = {
  letter: { h: 1294.12, pt: [612, 792], label: 'Letter' },
  a4: { h: 1414.29, pt: [595.28, 841.89], label: 'A4' },
  wide: { h: 562.5, pt: [960, 540], label: 'Widescreen' },
};
export const PAPERS = ['blank', 'lines', 'grid', 'dots', 'eng'];

export const newId = () => {
  const b = new Uint8Array(6);
  crypto.getRandomValues(b);
  return [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
};
export const now = () => Date.now();

export function blankPage(sec, size = 'letter', paper = 'lines', t = now()) {
  const s = SIZES[size] || SIZES.letter;
  return { id: newId(), t, sec, w: PAGE_W, h: s.h, paper, bg: null, pt: [...s.pt], title: '', strokes: [], gone: [] };
}

export function newNotebook(title = 'Notebook', size = 'letter', section = 'Notes', paper = 'lines') {
  const t = now();
  const sec = newId();
  const page = blankPage(sec, size, paper, t);
  return finish({
    v: 1, id: newId(), title, size, folder: '', metaT: t, created: t,
    layout: { t, sections: [{ id: sec, title: section, pages: [page.id] }] },
    goneP: [], pages: { [page.id]: page },
  });
}

export const order = (nb) => nb.layout.sections.flatMap((s) => s.pages);
export const sectionOf = (nb, pid) => nb.layout.sections.find((s) => s.pages.includes(pid));

// Fill in what an older or partial copy may lack.
export function normalize(nb) {
  nb.v = 1;
  nb.title ??= 'Untitled notebook';
  nb.size = SIZES[nb.size] ? nb.size : 'letter';
  nb.folder ??= '';
  nb.metaT ??= 0;
  nb.created ??= 0;
  nb.layout ??= { t: 0, sections: [] };
  nb.goneP ??= [];
  nb.pages ??= {};
  for (const [id, p] of Object.entries(nb.pages)) {
    p.id = id;
    p.t ??= 0;
    p.sec ??= '';
    p.w = PAGE_W;
    p.paper ??= 'blank';
    p.bg ??= null;
    p.pt ??= [612, 792];
    p.title ??= '';
    p.strokes ??= [];
    p.gone ??= [];
  }
  return nb;
}

// ---------------------------------------------------------------- merge

const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const tuple = (x, y) => (x.length ? x.reduce((r, v, i) => r || cmp(v, y[i]), 0) : 0);
const bgKey = (bg) => (bg ? bg.pdf || bg.img || (bg.live ? 'live' : '') : '');
const metaKey = (p) => [p.t, `${p.sec}|${p.paper}|${bgKey(p.bg)}|${p.bg?.n ?? ''}`];
const layoutKey = (l) => [l.t, l.sections.map((s) => `${s.id}:${s.title}:${s.pages.join(',')}`).join('|')];
const byZ = (a, b) => a.z - b.z || cmp(a.id, b.id);

function mergePage(a, b) {
  const meta = tuple(metaKey(a), metaKey(b)) >= 0 ? a : b;
  const gone = new Set([...a.gone, ...b.gone]);
  const strokes = new Map();
  for (const s of [...a.strokes, ...b.strokes]) {
    if (gone.has(s.id)) continue;
    const old = strokes.get(s.id);
    if (!old || s.pts.length > old.pts.length) strokes.set(s.id, s);
  }
  return {
    id: a.id, t: meta.t, sec: meta.sec, w: PAGE_W, h: meta.h, paper: meta.paper, bg: meta.bg, pt: meta.pt, title: meta.title ?? '',
    strokes: [...strokes.values()].sort(byZ),
    gone: [...gone].sort(),
  };
}

export function merge(a, b) {
  if (!a) return b;
  if (!b) return a;
  const meta = tuple([a.metaT, a.title, a.size, a.folder ?? ''], [b.metaT, b.title, b.size, b.folder ?? '']) >= 0 ? a : b;
  const created = [a.created, b.created].filter(Boolean);
  const goneP = new Set([...a.goneP, ...b.goneP]);
  const pages = {};
  for (const id of new Set([...Object.keys(a.pages), ...Object.keys(b.pages)])) {
    if (goneP.has(id)) continue;
    const pa = a.pages[id], pb = b.pages[id];
    // Only one copy has it: still in stacking order, so merging is stable.
    pages[id] = pa && pb ? mergePage(pa, pb) : { ...(pa || pb), strokes: [...(pa || pb).strokes].sort(byZ) };
  }
  return finish({
    v: 1, id: a.id, title: meta.title, size: meta.size, folder: meta.folder ?? '', metaT: meta.metaT,
    created: created.length ? Math.min(...created) : 0,
    layout: tuple(layoutKey(a.layout), layoutKey(b.layout)) >= 0 ? a.layout : b.layout,
    goneP: [...goneP].sort(),
    pages,
  });
}

// The layout lists exactly the live pages; unlisted ones join their section.
export function finish(nb) {
  const gone = new Set(nb.goneP);
  const alive = new Set(Object.keys(nb.pages).filter((id) => !gone.has(id)));
  const seen = new Set();
  let sections = nb.layout.sections.map((s) => {
    const pages = s.pages.filter((id) => alive.has(id) && !seen.has(id));
    pages.forEach((id) => seen.add(id));
    return { id: s.id, title: s.title, pages, ...(s.color ? { color: s.color } : {}) };
  });
  if (!sections.length) sections = [{ id: 'main', title: 'Notes', pages: [] }];
  const byId = new Map(sections.map((s) => [s.id, s]));
  for (const id of [...alive].filter((id) => !seen.has(id)).sort()) {
    (byId.get(nb.pages[id].sec) || sections[sections.length - 1]).pages.push(id);
  }
  nb.layout = { t: nb.layout.t, sections };
  for (const id of Object.keys(nb.pages)) if (!alive.has(id)) delete nb.pages[id];
  return nb;
}

export async function digest(nb) {
  const parts = [`m:${nb.metaT}`, `l:${nb.layout.t}`, 'g:' + nb.goneP.join(',')];
  for (const id of Object.keys(nb.pages).sort()) {
    const p = nb.pages[id];
    const ink = p.strokes.map((s) => `${s.id}.${s.pts.length}`).sort().join(',');
    parts.push(`p:${id}:${p.t}:${ink}:${p.gone.join(',')}`);
  }
  return (await sha256Hex(new TextEncoder().encode(parts.join('\n')))).slice(0, 32);
}

export function assets(nb) {
  const out = new Set();
  for (const p of Object.values(nb.pages)) {
    if (p.bg?.pdf) out.add(p.bg.pdf);
    if (p.bg?.img) out.add(p.bg.img);
  }
  return out;
}

// ---------------------------------------------------------------- SHA-256
// crypto.subtle only exists on secure (HTTPS) pages; the app is also served
// over plain HTTP from the computer, so there's a fallback.

export async function sha256Hex(bytes) {
  if (globalThis.crypto?.subtle) {
    const d = await crypto.subtle.digest('SHA-256', bytes);
    return [...new Uint8Array(d)].map((x) => x.toString(16).padStart(2, '0')).join('');
  }
  return sha256Fallback(bytes);
}

const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98,
  0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8,
  0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
  0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
  0xc67178f2,
]);

function sha256Fallback(data) {
  const h = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
  const n = data.length;
  const total = Math.ceil((n + 9) / 64) * 64;
  const tail = new Uint8Array(total - Math.floor(n / 64) * 64);
  tail.set(data.subarray(Math.floor(n / 64) * 64));
  tail[n % 64] = 0x80;
  const bits = n * 8;
  const tv = new DataView(tail.buffer);
  tv.setUint32(tail.length - 8, Math.floor(bits / 0x100000000));
  tv.setUint32(tail.length - 4, bits >>> 0);
  const w = new Uint32Array(64);
  const block = (view, off) => {
    for (let i = 0; i < 16; i++) w[i] = view.getUint32(off + i * 4);
    for (let i = 16; i < 64; i++) {
      const a = w[i - 15], b = w[i - 2];
      const s0 = ((a >>> 7) | (a << 25)) ^ ((a >>> 18) | (a << 14)) ^ (a >>> 3);
      const s1 = ((b >>> 17) | (b << 15)) ^ ((b >>> 19) | (b << 13)) ^ (b >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
    }
    let [A, B, C, D, E, F, G, H] = h;
    for (let i = 0; i < 64; i++) {
      const S1 = ((E >>> 6) | (E << 26)) ^ ((E >>> 11) | (E << 21)) ^ ((E >>> 25) | (E << 7));
      const t1 = (H + S1 + ((E & F) ^ (~E & G)) + K[i] + w[i]) | 0;
      const S0 = ((A >>> 2) | (A << 30)) ^ ((A >>> 13) | (A << 19)) ^ ((A >>> 22) | (A << 10));
      const t2 = (S0 + ((A & B) ^ (A & C) ^ (B & C))) | 0;
      H = G; G = F; F = E; E = (D + t1) | 0; D = C; C = B; B = A; A = (t1 + t2) | 0;
    }
    h[0] += A; h[1] += B; h[2] += C; h[3] += D; h[4] += E; h[5] += F; h[6] += G; h[7] += H;
  };
  const main = new DataView(data.buffer, data.byteOffset, data.byteLength);
  for (let off = 0; off + 64 <= n; off += 64) block(main, off);
  for (let off = 0; off < tail.length; off += 64) block(tv, off);
  return [...h].map((x) => x.toString(16).padStart(8, '0')).join('');
}

// ---------------------------------------------------------------- live edits

// Index of stroke id -> [stroke, page] for a notebook.
export function indexStrokes(nb) {
  const m = new Map();
  for (const p of Object.values(nb.pages)) for (const s of p.strokes) m.set(s.id, [s, p]);
  return m;
}

// Apply a relayed live edit. Returns the affected page (or null).
export function applyOp(nb, idx, msg) {
  const page = msg.page ? nb.pages[msg.page] : null;
  switch (msg.t) {
    case 'begin': {
      if (!page || idx.has(msg.s.id) || page.gone.includes(msg.s.id)) return null;
      const s = { ...msg.s, pts: [...(msg.s.pts || [])] };
      page.strokes.push(s);
      idx.set(s.id, [s, page]);
      return page;
    }
    case 'pts': {
      const e = idx.get(msg.id);
      if (e) e[0].pts.push(...msg.pts);
      return e ? e[1] : null;
    }
    case 'remove': {
      if (!page) return null;
      const ids = new Set(msg.ids);
      page.strokes = page.strokes.filter((s) => !ids.has(s.id));
      page.gone = [...new Set([...page.gone, ...ids])].sort();
      ids.forEach((i) => idx.delete(i));
      return page;
    }
    case 'restore': {
      if (!page) return null;
      for (const s of msg.strokes) {
        if (idx.has(s.id) || page.gone.includes(s.id)) continue;
        page.strokes.push(s);
        idx.set(s.id, [s, page]);
      }
      page.strokes.sort(byZ);
      return page;
    }
  }
  return null;
}

// A partial notebook carrying only what a structural edit changed.
export function partial(nb, { meta = false, layout = false, pages = [], goneP = [] } = {}) {
  const out = { id: nb.id, goneP, pages: {} };
  if (meta) Object.assign(out, { title: nb.title, size: nb.size, folder: nb.folder ?? '', metaT: nb.metaT });
  if (layout) out.layout = nb.layout;
  for (const id of pages) {
    const p = nb.pages[id];
    if (p) out.pages[id] = { ...p, strokes: [], gone: [] };
  }
  return out;
}

// Merge a partial into nb in place (keeps object identity for callers).
export function mergeInto(nb, part) {
  const full = normalize({ metaT: 0, layout: { t: 0, sections: [] }, ...structuredClone(part) });
  if (!('title' in part)) Object.assign(full, { title: nb.title, size: nb.size, folder: nb.folder ?? '', metaT: 0 });
  const m = merge(nb, full);
  for (const k of Object.keys(nb)) delete nb[k];
  Object.assign(nb, m);
  return nb;
}
