// Notebooks on this device (IndexedDB). Each page is its own record so saving
// a stroke doesn't rewrite the whole notebook.
//
//   nbs     notebook meta: id, title, size, layout, goneP, dirty, synced digest
//   pages   [nb id, page id] -> page (strokes included)
//   assets  sha256 -> Blob (PDFs and images pages show)
//   kv      settings and the computer this app is paired with

import { finish, normalize } from './model.js';

const DB = 'openpad';
let dbp = null;

function open() {
  dbp ??= new Promise((res, rej) => {
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => {
      const db = r.result;
      db.createObjectStore('nbs', { keyPath: 'id' });
      db.createObjectStore('pages', { keyPath: ['nb', 'id'] }).createIndex('nb', 'nb');
      db.createObjectStore('assets');
      db.createObjectStore('kv');
    };
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
  return dbp;
}

const done = (req) => new Promise((res, rej) => {
  req.onsuccess = () => res(req.result);
  req.onerror = () => rej(req.error);
});
const txDone = (tx) => new Promise((res, rej) => {
  tx.oncomplete = () => res();
  tx.onerror = tx.onabort = () => rej(tx.error || new Error('storage failed'));
});

// Ask the browser not to clear our data when space runs low.
export async function persist() {
  try {
    return (await navigator.storage?.persist?.()) ?? false;
  } catch {
    return false;
  }
}

export async function kvGet(key, fallback = null) {
  const db = await open();
  const v = await done(db.transaction('kv').objectStore('kv').get(key));
  return v ?? fallback;
}
export async function kvSet(key, value) {
  const db = await open();
  const tx = db.transaction('kv', 'readwrite');
  tx.objectStore('kv').put(value, key);
  return txDone(tx);
}

const META = ['id', 'v', 'title', 'size', 'metaT', 'created', 'layout', 'goneP'];

// All notebooks' meta (no pages), including deleted ones (`deleted` set).
export async function listNotebooks() {
  const db = await open();
  return done(db.transaction('nbs').objectStore('nbs').getAll());
}

export async function loadNotebook(id) {
  const db = await open();
  const tx = db.transaction(['nbs', 'pages']);
  const meta = await done(tx.objectStore('nbs').get(id));
  if (!meta || meta.deleted) return null;
  const pages = await done(tx.objectStore('pages').index('nb').getAll(id));
  const nb = { pages: {} };
  for (const k of META) if (k in meta) nb[k] = meta[k];
  for (const p of pages) {
    const { nb: _, ...page } = p;
    nb.pages[page.id] = page;
  }
  return finish(normalize(nb));
}

// Save a notebook. `pageIds` limits which pages are written (null = all);
// pages no longer in the notebook are deleted.
export async function saveNotebook(nb, pageIds = null, flags = {}) {
  const db = await open();
  const tx = db.transaction(['nbs', 'pages'], 'readwrite');
  const nbs = tx.objectStore('nbs');
  const pages = tx.objectStore('pages');
  const old = (await done(nbs.get(nb.id))) || {};
  const meta = { ...old, dirty: true, ...flags };
  for (const k of META) meta[k] = nb[k];
  meta.pageCount = Object.keys(nb.pages).length;
  meta.modified = Math.max(nb.metaT, nb.layout.t, ...Object.values(nb.pages).map((p) => p.t), old.modified || 0);
  if (flags.touched) meta.modified = Date.now();
  delete meta.touched;
  nbs.put(meta);
  const ids = pageIds ?? Object.keys(nb.pages);
  for (const id of ids) if (nb.pages[id]) pages.put({ ...nb.pages[id], nb: nb.id });
  if (pageIds === null || nb.goneP.length) {
    const keys = await done(pages.index('nb').getAllKeys(nb.id));
    for (const key of keys) if (!nb.pages[key[1]]) pages.delete(key);
  }
  return txDone(tx);
}

export async function setFlags(id, flags) {
  const db = await open();
  const tx = db.transaction('nbs', 'readwrite');
  const st = tx.objectStore('nbs');
  const meta = await done(st.get(id));
  if (meta) st.put({ ...meta, ...flags });
  return txDone(tx);
}

// Deleting keeps a marker, so sync tells the computer and doesn't bring it back.
export async function deleteNotebook(id) {
  const db = await open();
  const tx = db.transaction(['nbs', 'pages'], 'readwrite');
  const meta = (await done(tx.objectStore('nbs').get(id))) || { id };
  tx.objectStore('nbs').put({ id, title: meta.title, deleted: Date.now(), dirty: true });
  const keys = await done(tx.objectStore('pages').index('nb').getAllKeys(id));
  for (const key of keys) tx.objectStore('pages').delete(key);
  return txDone(tx);
}

export async function forget(id) {
  const db = await open();
  const tx = db.transaction('nbs', 'readwrite');
  tx.objectStore('nbs').delete(id);
  return txDone(tx);
}

export async function getAsset(sha) {
  const db = await open();
  return done(db.transaction('assets').objectStore('assets').get(sha));
}
export async function hasAsset(sha) {
  const db = await open();
  return (await done(db.transaction('assets').objectStore('assets').getKey(sha))) !== undefined;
}
export async function putAsset(sha, blob) {
  const db = await open();
  const tx = db.transaction('assets', 'readwrite');
  tx.objectStore('assets').put(blob, sha);
  return txDone(tx);
}

export async function usage() {
  try {
    return await navigator.storage.estimate();
  } catch {
    return null;
  }
}
