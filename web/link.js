// The connection to the computer: pairing, the live-session WebSocket, and
// syncing every notebook (plus the PDFs and images pages show) both ways.
//
// The app runs either from the computer itself (http://<computer>:8770/?k=…,
// same origin) or installed from GitHub Pages (HTTPS, works offline), where
// it reaches the computer at https://<address> with OpenPad's own certificate.

import { assets, digest, merge, mergeInto, normalize, order, sha256Hex } from './model.js';
import * as store from './store.js';
import { Backgrounds, buildPDF } from './ink.js';

export class Link {
  constructor({ base, key, name = '' }) {
    this.base = base.replace(/\/$/, '');
    this.key = key;
    this.name = name;
  }

  static async fromPage() {
    // Opened from the computer's pairing link: same origin, key in the URL.
    const k = new URLSearchParams(location.search).get('k');
    if (k && location.protocol === 'http:') {
      const link = new Link({ base: location.origin, key: k });
      await store.kvSet('pc', { base: link.base, key: k, name: '' });
      return link;
    }
    const saved = await store.kvGet('pc');
    if (saved?.base && saved?.key) {
      // A pairing saved for another origin only works if this page may reach it.
      if (location.protocol === 'https:' && saved.base.startsWith('http:')) return null;
      return new Link(saved);
    }
    return null;
  }

  // Trade the 6-digit PIN shown on the computer for the key.
  static async pair(address, pin) {
    const host = address.trim().replace(/^https?:\/\//, '').replace(/\/.*$/, '');
    const withPort = /:\d+$/.test(host) ? host : `${host}:8770`;
    const scheme = location.protocol === 'https:' ? 'https' : 'http';
    const base = `${scheme}://${withPort}`;
    let r;
    try {
      r = await fetch(`${base}/api/pair`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ pin: pin.trim() }),
      });
    } catch {
      throw new Error(scheme === 'https'
        ? `Couldn't reach ${withPort}. Check the address, that both devices are on the same Wi-Fi, and that this iPad trusts the OpenPad certificate (see Set up on the computer's Pair screen).`
        : `Couldn't reach ${withPort}.`);
    }
    if (!r.ok) throw new Error(r.status === 403 ? 'Wrong or expired PIN. Check the PIN on the computer and try again.' : `Pairing failed (${r.status})`);
    const { k, name } = await r.json();
    const link = new Link({ base, key: k, name });
    await store.kvSet('pc', { base, key: k, name });
    return link;
  }

  url(path) {
    return `${this.base}${path}`;
  }

  async api(path, { method = 'GET', body, headers = {}, json = true } = {}) {
    const r = await fetch(this.url(path), {
      method,
      body,
      headers: { 'X-OpenPad-Key': this.key, ...headers },
      cache: 'no-store',
    });
    if (!r.ok) {
      const j = await r.json().catch(() => ({}));
      const e = new Error(j.error || `${method} ${path} failed (${r.status})`);
      e.status = r.status;
      throw e;
    }
    return json ? r.json() : r;
  }

  assetURL(sha) {
    return this.url(`/api/asset/${sha}?k=${encodeURIComponent(this.key)}`);
  }

  wsURL(role) {
    return `${this.base.replace(/^http/, 'ws')}/ws?role=${role}&k=${encodeURIComponent(this.key)}`;
  }
}

// ---------------------------------------------------------------- WebSocket

// Reconnecting socket. Owner apps drop edits made while offline (they're
// saved locally and sync later); guests queue them and send after reconnecting.
export function socket(url, handlers, { queueOffline = false } = {}) {
  let ws = null;
  let queue = [];
  let retry = 250;
  let closed = false;
  const api = {
    connected: false,
    send(msg) {
      const s = JSON.stringify(msg);
      if (ws && ws.readyState === 1) ws.send(s);
      else if (queueOffline && msg.t !== 'cursor') queue.push(s);
    },
    sendBinary(data) {
      if (ws && ws.readyState === 1) ws.send(data);
    },
    bufferedAmount() {
      return ws ? ws.bufferedAmount : 0;
    },
    close() {
      closed = true;
      ws?.close();
    },
  };
  function open() {
    if (closed) return;
    ws = new WebSocket(url);
    ws.binaryType = 'blob';
    ws.onopen = () => {
      retry = 250;
      api.connected = true;
      handlers.status?.(true);
    };
    ws.onmessage = (e) => {
      if (typeof e.data !== 'string') return handlers.frame?.(e.data); // live window frame (JPEG)
      const msg = JSON.parse(e.data);
      handlers.message(msg);
      // Flush only after the fresh state arrived, so queued edits apply on top of it.
      if (msg.t === 'state' && queue.length) {
        for (const s of queue) ws.send(s);
        queue = [];
      }
    };
    ws.onclose = () => {
      api.connected = false;
      handlers.status?.(false);
      if (closed) return;
      setTimeout(open, retry);
      retry = Math.min(retry * 2, 5000);
    };
  }
  open();
  return api;
}

// ---------------------------------------------------------------- sync

// Page backgrounds come from this device first, then the computer (and are kept).
export function localBackgrounds(getLink) {
  return new Backgrounds(async (sha) => {
    const blob = await store.getAsset(sha);
    if (blob) return blob.arrayBuffer();
    const link = getLink();
    if (!link) throw new Error('not on this device');
    const r = await fetch(link.assetURL(sha));
    if (!r.ok) throw new Error('missing');
    const b = await r.blob();
    await store.putAsset(sha, b);
    return b.arrayBuffer();
  });
}

export async function importAsset(bytes, type) {
  const sha = await sha256Hex(bytes);
  if (!(await store.hasAsset(sha))) await store.putAsset(sha, new Blob([bytes], { type }));
  return sha;
}

const sectionDigest = (nb, sec) => sec.title + '|' + sec.pages.map((id) => {
  const p = nb.pages[id];
  return `${id}:${p.t}:${p.strokes.length}:${p.strokes.reduce((n, s) => n + s.pts.length, 0)}:${p.gone.length}`;
}).join(',');

export class Sync {
  constructor(link, { onstatus, onchanged, backgrounds, busy }) {
    this.link = link;
    this.onstatus = onstatus || (() => {});
    this.onchanged = onchanged || (() => {});
    this.backgrounds = backgrounds;
    this.busy = busy || (() => false); // true while drawing: PDF copies wait
    this.running = null;
    this.again = false;
    this.state = 'idle';
    this.lastOk = 0;
    this.pdfQueue = new Map(); // nb id -> due time
  }

  status(state, detail = '') {
    this.state = state;
    this.onstatus(state, detail);
  }

  // Sync everything (or one notebook). Calls overlapping a running sync are
  // folded into one more pass afterwards.
  run(only = null) {
    if (this.running) {
      this.again = true;
      return this.running;
    }
    this.running = (async () => {
      try {
        do {
          this.again = false;
          await this.#pass(only);
        } while (this.again);
        this.lastOk = Date.now();
        this.status('ok');
      } catch (e) {
        this.status(e.status === 403 ? 'unpaired' : 'offline', e.message);
      } finally {
        this.running = null;
      }
    })();
    return this.running;
  }

  async #pass(only) {
    this.status('syncing');
    const remote = await this.link.api('/api/sync');
    const local = await store.listNotebooks();
    const remoteById = new Map(remote.notebooks.map((n) => [n.id, n]));
    const localIds = new Set(local.map((n) => n.id));
    for (const meta of local) {
      if (only && meta.id !== only) continue;
      if (meta.deleted) {
        await this.link.api('/api/sync/delete', { method: 'POST', body: JSON.stringify({ id: meta.id, t: meta.deleted }), headers: { 'Content-Type': 'application/json' } });
        await store.forget(meta.id);
        continue;
      }
      if (remote.deleted[meta.id]) {
        // Deleted on another device: deletes win.
        await store.deleteNotebook(meta.id);
        await store.forget(meta.id);
        this.onchanged(meta.id, null);
        continue;
      }
      const nb = await store.loadNotebook(meta.id);
      if (!nb) continue;
      const d = await digest(nb);
      const r = remoteById.get(meta.id);
      if (r && r.d === d) {
        if (meta.dirty) await store.setFlags(meta.id, { dirty: false, synced: d });
        await this.#assets(nb, []);
        continue;
      }
      await this.push(nb, d);
    }
    for (const r of remote.notebooks) {
      if (only && r.id !== only) continue;
      if (localIds.has(r.id)) continue;
      const nb = normalize(await this.link.api(`/api/sync/nb/${r.id}`));
      await store.saveNotebook(nb, null, { dirty: false, synced: r.d });
      await this.#assets(nb, []);
      this.onchanged(nb.id, nb);
      this.queuePDF(nb.id);
    }
    await this.#pdfs();
  }

  // Send one notebook; merge back whatever the computer had that we didn't.
  async push(nb, d = null) {
    d ??= await digest(nb);
    const res = await this.link.api('/api/sync/nb', {
      method: 'POST',
      body: JSON.stringify(nb),
      headers: { 'Content-Type': 'application/json', 'X-OpenPad-Digest': d },
    });
    if (res.deleted) {
      await store.deleteNotebook(nb.id);
      await store.forget(nb.id);
      this.onchanged(nb.id, null);
      return;
    }
    let result = nb;
    if (res.nb) {
      // Merge into the latest local copy: it may have changed meanwhile.
      const latest = (await store.loadNotebook(nb.id)) || nb;
      result = merge(latest, normalize(res.nb));
      await store.saveNotebook(result, null, { dirty: (await digest(result)) !== res.d, synced: res.d });
      this.onchanged(nb.id, result);
    } else {
      await store.setFlags(nb.id, { dirty: false, synced: res.d });
    }
    await this.#assets(result, res.missing || []);
    this.queuePDF(nb.id);
  }

  // Upload files the computer lacks; download ones this device lacks.
  async #assets(nb, missing) {
    for (const sha of missing) {
      const blob = await store.getAsset(sha);
      if (blob) await this.link.api(`/api/asset/${sha}`, { method: 'PUT', body: blob, json: true });
    }
    for (const sha of assets(nb)) {
      if (missing.includes(sha) || (await store.hasAsset(sha))) continue;
      try {
        const r = await fetch(this.link.assetURL(sha));
        if (r.ok) await store.putAsset(sha, await r.blob());
      } catch {}
    }
  }

  // ---------------------------------------------------------------- readable PDFs

  // Rebuild changed sections as PDFs in the computer's OpenPad folder, a
  // little after the last change (and never while the pen is down).
  queuePDF(id, delay = 45000) {
    const due = Date.now() + delay;
    this.pdfQueue.set(id, Math.min(this.pdfQueue.get(id) ?? Infinity, due));
  }

  async #pdfs(force = false) {
    for (const [id, due] of [...this.pdfQueue]) {
      if (!force && (due > Date.now() || this.busy())) continue;
      this.pdfQueue.delete(id);
      const nb = await store.loadNotebook(id);
      if (!nb) continue;
      const done = (await store.kvGet(`pdf:${id}`)) || {};
      for (const sec of nb.layout.sections) {
        const d = sectionDigest(nb, sec);
        if (done[sec.id] === d || !sec.pages.length) continue;
        if (!force && this.busy()) {
          this.queuePDF(id, 5000);
          break;
        }
        const pages = sec.pages.map((pid) => nb.pages[pid]);
        const blob = await buildPDF(pages, { backgrounds: this.backgrounds, title: `${nb.title} – ${sec.title}` });
        await this.link.api(`/api/sync/pdf/${id}/${sec.id}`, { method: 'PUT', body: blob });
        done[sec.id] = d;
        await store.kvSet(`pdf:${id}`, done);
      }
    }
  }

  flushPDFs() {
    return this.#pdfs(true).catch(() => {});
  }

  tickPDFs() {
    if (this.pdfQueue.size && !this.running) this.#pdfs().catch(() => {});
  }
}

export { order, mergeInto };
