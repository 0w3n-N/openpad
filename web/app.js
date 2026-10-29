// The notes app: notebooks stored on this device, synced to the paired
// computer, and shown live on it (plus to invited guests) while open.

import { COLORS, buildPDF, drawStroke, pdfInfo, pdfName, savePDF, shapePressure } from './ink.js';
import { Editor } from './editor.js';
import { Link, Sync, importAsset, localBackgrounds, socket } from './link.js';
import { blankPage, digest, mergeInto, newId, newNotebook, normalize, now, order, sectionOf } from './model.js';
import * as store from './store.js';

const $ = (s) => document.querySelector(s);
const $$ = (s) => document.querySelectorAll(s);

// ---------------------------------------------------------------- settings

const settings = { pressure: 0.35, doubleTap: true, fingerDraw: false };
try {
  Object.assign(settings, JSON.parse(localStorage.getItem('openpad.settings') || '{}'));
} catch {}
const saveSettings = () => {
  try {
    localStorage.setItem('openpad.settings', JSON.stringify(settings));
  } catch {}
};

let toastTimer = 0;
function toast(text, ms = 2500) {
  const t = $('#toast');
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toastTimer);
  if (ms) toastTimer = setTimeout(() => (t.hidden = true), ms);
}

// ---------------------------------------------------------------- the computer

let link = await Link.fromPage();
let sync = null;
let ws = null;
let live = { ready: false, peers: { views: 0, guests: 0, pads: 0 }, state: 'idle', capture: 'native' };
let cast = localStorage.getItem('openpad.cast') !== '0';
const backgrounds = localBackgrounds(() => link);
store.persist();

// Clean the key out of the address bar on the computer's own page (it stays
// in localStorage-free IndexedDB). Keep it if the page might be added to the
// Home Screen, which needs the full link.
if (link && location.search.includes('k=') && !navigator.standalone) {
  /* leave the URL alone: Add to Home Screen uses it */
}

function setPill(state, detail = '') {
  const pill = $('#pcpill');
  pill.dataset.state = state;
  const name = link?.name || (link ? new URL(link.base).hostname : '');
  $('#pctext').textContent =
    !link ? 'This iPad only · Pair' :
    state === 'syncing' ? 'Syncing…' :
    state === 'ok' ? `Synced with ${name}` :
    state === 'unpaired' ? 'Pairing expired · Pair again' :
    `Offline · ${name}`;
  pill.title = detail || '';
}

function startLink() {
  if (!link) return setPill('none');
  useTheme();
  sync = new Sync(link, {
    backgrounds,
    busy: () => !!editor?.drawing,
    onstatus: setPill,
    onchanged: (id, nb) => {
      if (current && id === current.id) {
        if (!nb) return closeNotebook(true);
        mergeInto(current, nb);
        editor.refresh();
      }
      renderLibrary();
    },
  });
  sync.run();
  ws = socket(link.wsURL('pad'), { status: onSocket, message: onMessage, frame: (b) => editor.surface.pushFrame(b) });
}

function useTheme() {
  let el = $('#theme');
  if (!el) {
    el = document.createElement('link');
    el.id = 'theme';
    el.rel = 'stylesheet';
    document.head.append(el);
  }
  el.href = link.url(`/theme.css?k=${encodeURIComponent(link.key)}&v=${Date.now()}`);
}

function onSocket(ok) {
  live.ready = false;
  if (ok) {
    sync?.run();
    if (current) castCurrent();
  }
  syncLiveBadge();
}

// Put the open notebook on the computer's screen (after it's synced there).
async function castCurrent() {
  if (!ws?.connected || !current || !cast) return;
  const id = current.id;
  await sync.push(current).catch(() => {});
  if (current?.id === id) ws.send({ t: 'open', id, page: editor.pid });
}

function send(msg) {
  if (live.ready && cast) ws?.send(msg);
}

function onMessage(msg) {
  if (msg.t === 'theme') return useTheme();
  if (msg.t === 'peers') {
    live.peers = msg;
    return syncLiveBadge();
  }
  if (msg.t === 'error') return toast(msg.error, 4000);
  if (msg.t === 'live') return onLiveMessage(msg);
  if (msg.t === 'state') {
    live.peers = msg;
    live.capture = msg.capture;
    live.state = msg.live?.state || 'idle';
    syncLiveBadge();
    if (!current || !cast) return;
    if (msg.nb.id !== current.id) {
      live.ready = false;
      return castCurrent();
    }
    live.ready = true;
    syncLiveBadge();
    mergeInto(current, normalize(msg.nb));
    editor.refresh();
    if (msg.page && msg.page !== editor.pid && current.pages[msg.page]) editor.show(msg.page, true);
    saveSoon(null);
    // Anything the computer's copy lacks (edits made offline) goes over HTTP.
    Promise.all([digest(current), digest(normalize(msg.nb))]).then(([a, b]) => a !== b && sync?.push(current));
    return;
  }
  if (!live.ready || !current || !cast) return;
  if (msg.t === 'merge') {
    if (msg.nb.id !== current.id) return;
    mergeInto(current, msg.nb);
    editor.refresh();
    return saveSoon(null);
  }
  if (msg.t === 'goto') {
    if (current.pages[msg.page]) editor.show(msg.page, true);
    return;
  }
  if (msg.t === 'cursor') return;
  const page = editor.applyRemote(msg);
  if (page && msg.t !== 'pts' && msg.t !== 'begin') saveSoon([page.id]);
}

function onLiveMessage(msg) {
  if (msg.state === 'needs-desktop') {
    return toast(live.peers.views > 0
      ? 'On your computer, click "Choose a window" in the OpenPad window.'
      : 'Open the OpenPad window on your computer first, then try again.', 5000);
  }
  if (msg.state === 'source-stop') return;
  live.state = msg.state === 'error' ? 'idle' : msg.state;
  const text = {
    picking: 'Choose the window in the picker on your computer…',
    live: 'The window is live. Draw on it.',
  }[msg.state] || (msg.state === 'error' ? msg.error : {
    cancelled: 'Window sharing cancelled',
    closed: 'The window closed. Its last frame stays on the page.',
    stopped: 'Stopped. The last frame stays on the page.',
    error: msg.error || 'Window capture stopped',
  }[msg.reason]);
  if (text) toast(text, msg.state === 'picking' ? 0 : 3500);
  $('#m-window').textContent = live.state === 'idle' ? 'Annotate a desktop window…' : 'Stop the live window';
}

function syncLiveBadge() {
  const b = $('#livebadge');
  const on = !!(ws?.connected && live.ready && cast);
  b.hidden = !link;
  b.classList.toggle('on', on);
  const n = (live.peers.views || 0) + (live.peers.guests || 0);
  $('#livecount').textContent = on ? (live.peers.guests ? `${live.peers.guests} guest${live.peers.guests > 1 ? 's' : ''}` : 'Live') : ws?.connected ? 'Not shown' : 'Offline';
  b.title = on ? `Shown on the computer${n ? ` (${live.peers.views} window${live.peers.views === 1 ? '' : 's'}, ${live.peers.guests} guests)` : ''}` : 'Not shown on the computer';
  $('#m-live').hidden = !link;
  $('#m-cast').checked = cast;
}

// ---------------------------------------------------------------- library

let current = null; // the open notebook

async function renderLibrary() {
  const list = (await store.listNotebooks()).filter((n) => !n.deleted).sort((a, b) => (b.modified || 0) - (a.modified || 0));
  const books = $('#books');
  books.replaceChildren();
  $('#empty').hidden = list.length > 0;
  for (const n of list) {
    const card = document.createElement('div');
    card.className = 'book';
    const open = document.createElement('button');
    open.className = 'cover';
    const t = document.createElement('strong');
    t.textContent = n.title;
    const meta = document.createElement('span');
    meta.className = 'muted small';
    const secs = n.layout?.sections?.length || 1;
    meta.textContent = `${secs} section${secs > 1 ? 's' : ''} · ${n.pageCount || 0} page${n.pageCount === 1 ? '' : 's'} · ${when(n.modified)}`;
    open.append(t, meta);
    open.onclick = () => openNotebook(n.id);
    const more = document.createElement('button');
    more.className = 'more';
    more.title = 'Rename, delete';
    more.textContent = '⋯';
    more.onclick = (e) => {
      e.stopPropagation();
      bookMenu(n);
    };
    const dot = document.createElement('span');
    dot.className = 'syncdot' + (link ? (n.dirty ? ' dirty' : ' synced') : '');
    dot.title = !link ? 'Only on this device' : n.dirty ? 'Changes not synced yet' : 'Synced';
    card.append(open, more, dot);
    books.append(card);
  }
}

function when(t) {
  if (!t) return '';
  const d = new Date(t);
  const today = new Date();
  if (d.toDateString() === today.toDateString()) return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  return d.toLocaleDateString([], { month: 'short', day: 'numeric', year: d.getFullYear() === today.getFullYear() ? undefined : 'numeric' });
}

async function bookMenu(n) {
  const choice = await ask({ title: n.title, select: [['rename', 'Rename'], ['pdf', 'Save as PDF…'], ['delete', 'Delete']], ok: 'Go' });
  if (choice === 'rename') {
    const title = await ask({ title: 'Rename notebook', value: n.title, ok: 'Rename' });
    if (!title) return;
    const nb = await store.loadNotebook(n.id);
    Object.assign(nb, { title: title.slice(0, 120), metaT: now() });
    await store.saveNotebook(nb, [], { touched: true });
    sync?.run(n.id);
    renderLibrary();
  } else if (choice === 'pdf') {
    const nb = await store.loadNotebook(n.id);
    exportPages(nb, order(nb), nb.title);
  } else if (choice === 'delete') {
    const ok = await ask({ title: `Delete “${n.title}”?`, text: link ? 'It is also removed from the computer (kept in its trash folder for a while).' : 'This can’t be undone.', ok: 'Delete' });
    if (ok === null) return;
    await store.deleteNotebook(n.id);
    sync?.run();
    renderLibrary();
  }
}

async function createNotebook() {
  const title = await ask({ title: 'New notebook', value: 'Notes', ok: 'Next', text: 'Name it after a course, e.g. “Physics 2A”.' });
  if (!title) return;
  const size = await ask({ title: 'Page size', select: [['letter', 'Letter (portrait)'], ['a4', 'A4 (portrait)'], ['wide', 'Widescreen (good for sharing on calls)']], ok: 'Create' });
  if (!size) return;
  const nb = newNotebook(title.slice(0, 120), size, 'Notes', size === 'wide' ? 'grid' : 'lines');
  await store.saveNotebook(nb, null, { touched: true });
  openNotebook(nb.id);
}

// ---------------------------------------------------------------- PDFs in

async function readPDF(file) {
  if (file.size > 200 * 1024 * 1024) throw new Error('PDFs up to 200 MB are supported.');
  const bytes = new Uint8Array(await file.arrayBuffer());
  if (String.fromCharCode(...bytes.slice(0, 5)) !== '%PDF-') throw new Error('That file is not a PDF.');
  toast(`Reading ${file.name}…`, 0);
  const sizes = await pdfInfo(bytes);
  const sha = await importAsset(bytes, 'application/pdf');
  return { sha, sizes, name: file.name.replace(/\.pdf$/i, '').slice(0, 80) || 'PDF' };
}

function pdfPages(sec, { sha, sizes }, t = now()) {
  return sizes.map(([w, h], i) => {
    const p = blankPage(sec, 'letter', 'blank', t);
    return Object.assign(p, { h: Math.round((1000 * h) / w * 100) / 100, pt: [w, h], bg: { pdf: sha, n: i + 1 } });
  });
}

let importTarget = 'library';
async function onFile(file) {
  try {
    const pdf = await readPDF(file);
    if (importTarget === 'library') {
      const nb = newNotebook(pdf.name, 'letter', pdf.name, 'blank');
      const sec = nb.layout.sections[0];
      nb.pages = {};
      const pages = pdfPages(sec.id, pdf, nb.metaT);
      for (const p of pages) nb.pages[p.id] = p;
      sec.pages = pages.map((p) => p.id);
      await store.saveNotebook(nb, null, { touched: true });
      toast(`Imported ${pdf.name} (${pages.length} pages)`);
      await openNotebook(nb.id);
    } else {
      // A new section after the current one, so the PDF stays with its notes.
      const secId = newId();
      const pages = pdfPages(secId, pdf);
      for (const p of pages) current.pages[p.id] = p;
      const cur = sectionOf(current, editor.pid);
      const layout = { t: now(), sections: current.layout.sections.map((s) => ({ ...s, pages: [...s.pages] })) };
      const at = layout.sections.findIndex((s) => s.id === cur?.id);
      layout.sections.splice(at + 1, 0, { id: secId, title: pdf.name, pages: pages.map((p) => p.id) });
      current.layout = layout;
      await store.saveNotebook(current, pages.map((p) => p.id), { touched: true });
      if (live.ready) {
        await sync.push(current).catch(() => {});
        ws.send({ t: 'open', id: current.id, page: pages[0].id });
      }
      editor.setNotebook(current, pages[0].id);
      toast(`Added ${pdf.name} (${pages.length} pages)`);
    }
  } catch (e) {
    toast(e.message || 'Could not open the PDF', 5000);
  }
}

// ---------------------------------------------------------------- notebook

const editor = new Editor($('#stage'), {
  backgrounds,
  settings,
  toast,
  onop,
  onpage: (pid, changed) => {
    renderPager();
    if (!$('#side').hidden) renderSide();
    if (changed && current) store.kvSet(`last:${current.id}`, pid);
  },
});
editor.oncursor = (c) => send({ t: 'cursor', ...c });
editor.syncUndo = () => {
  $('#undo').disabled = !editor.undo.length;
  $('#redo').disabled = !editor.redo.length;
};
editor.onzoom = (z) => ($('#fitbtn').hidden = !z);
editor.ontool = (t) => $$('[data-tool]').forEach((b) => b.classList.toggle('on', b.dataset.tool === t));
editor.onpointer = () => closePops();

// Every change: save it here, send it to the live session.
const dirtyPages = new Set();
let saveTimer = 0;
let structural = false;
function saveSoon(pages, isStructural = false) {
  if (pages === null) structural = true;
  else pages.forEach((id) => dirtyPages.add(id));
  if (isStructural) structural = true;
  clearTimeout(saveTimer);
  saveTimer = setTimeout(flushSave, 400);
}
async function flushSave() {
  if (!current) return;
  const pages = structural ? null : [...dirtyPages];
  dirtyPages.clear();
  structural = false;
  await store.saveNotebook(current, pages, { touched: true }).catch((e) => toast('Saving failed: ' + e.message, 5000));
}

function onop(msg, info = {}) {
  if (msg.t === 'goto') {
    send(msg);
    return;
  }
  if (msg.t === 'merge') {
    send(msg);
    saveSoon(info.pages || [], true);
    return;
  }
  send(msg);
  if (info.pages) saveSoon(info.pages);
}

async function openNotebook(id) {
  const nb = await store.loadNotebook(id);
  if (!nb) return renderLibrary();
  current = nb;
  live.ready = false;
  $('#library').hidden = true;
  $('#editor').hidden = false;
  document.title = `${nb.title} · OpenPad`;
  editor.layout();
  const last = await store.kvGet(`last:${id}`);
  editor.setNotebook(nb, last);
  editor.syncUndo();
  syncLiveBadge();
  castCurrent();
}

async function closeNotebook(deleted = false) {
  clearTimeout(saveTimer);
  if (current && !deleted) await flushSave();
  const id = current?.id;
  current = null;
  live.ready = false;
  $('#editor').hidden = true;
  $('#library').hidden = false;
  closePops();
  document.title = 'OpenPad';
  renderLibrary();
  if (id && sync) sync.run(id).then(() => sync.queuePDF(id, 1000));
}

function renderPager() {
  if (!current) return;
  const pos = editor.position();
  const sec = pos.section;
  $('#pageno').textContent = sec && current.layout.sections.length > 1
    ? `${sec.title.slice(0, 14)} · ${pos.inSection + 1}/${sec.pages.length}`
    : `${pos.index + 1} / ${pos.count}`;
  $('#prev').disabled = pos.index <= 0;
  $('#next').disabled = pos.index >= pos.count - 1;
  $$('[data-paper]').forEach((b) => b.classList.toggle('on', b.dataset.paper === (editor.page?.paper || 'blank')));
}

// ---------------------------------------------------------------- sidebar

function renderSide() {
  $('#nbtitle').textContent = current.title;
  const root = $('#sections');
  root.replaceChildren();
  current.layout.sections.forEach((sec, si) => {
    const box = document.createElement('div');
    box.className = 'sec';
    const head = document.createElement('div');
    head.className = 'sechead';
    const name = document.createElement('button');
    name.className = 'secname';
    name.textContent = sec.title;
    name.title = 'Rename or delete';
    name.onclick = () => sectionMenu(sec, si);
    const add = document.createElement('button');
    add.className = 'small';
    add.textContent = '+ Page';
    add.onclick = () => editor.addPage(sec.pages[sec.pages.length - 1] || null);
    head.append(name, add);
    const pages = document.createElement('div');
    pages.className = 'thumbs';
    sec.pages.forEach((pid, i) => {
      const b = document.createElement('button');
      b.className = 'thumb' + (pid === editor.pid ? ' on' : '');
      b.onclick = () => editor.gotoPage(pid);
      const c = document.createElement('canvas');
      thumb(c, current.pages[pid]);
      const n = document.createElement('span');
      n.textContent = i + 1;
      b.append(c, n);
      pages.append(b);
    });
    box.append(head, pages);
    root.append(box);
  });
  root.querySelector('.thumb.on')?.scrollIntoView({ block: 'nearest' });
}

function thumb(c, page) {
  const w = 96;
  const k = w / page.w;
  c.width = w * 2;
  c.height = Math.round(page.h * k * 2);
  c.style.width = w + 'px';
  const ctx = c.getContext('2d');
  ctx.scale(2, 2);
  ctx.fillStyle = page.bg?.live ? '#000' : '#fff';
  ctx.fillRect(0, 0, w, page.h * k);
  const draw = () => {
    const img = backgrounds.get(page, 400, () => c.isConnected && draw());
    if (img) ctx.drawImage(img, 0, 0, w, page.h * k);
    for (const s of page.strokes) drawStroke(ctx, s, k);
  };
  draw();
}

async function sectionMenu(sec, si) {
  const n = current.layout.sections.length;
  const opts = [['rename', 'Rename'], ...(si > 0 ? [['up', 'Move up']] : []), ...(si < n - 1 ? [['down', 'Move down']] : []),
    ['pdf', 'Save section as PDF…'], ...(n > 1 ? [['delete', 'Delete section']] : [])];
  const choice = await ask({ title: sec.title, select: opts, ok: 'Go' });
  if (choice === 'rename') {
    const title = await ask({ title: 'Rename section', value: sec.title, ok: 'Rename' });
    if (title) editor.renameSection(sec.id, title.slice(0, 80));
  } else if (choice === 'up' || choice === 'down') editor.moveSection(sec.id, choice === 'up' ? -1 : 1);
  else if (choice === 'pdf') exportPages(current, sec.pages, `${current.title} - ${sec.title}`);
  else if (choice === 'delete') {
    const ok = await ask({ title: `Delete “${sec.title}” and its ${sec.pages.length} page(s)?`, ok: 'Delete' });
    if (ok !== null) editor.deleteSection(sec.id);
  }
  renderSide();
}

// ---------------------------------------------------------------- PDFs out

async function exportPages(nb, ids, title) {
  toast('Building PDF…', 0);
  try {
    const pages = ids.map((id) => nb.pages[id]).filter(Boolean);
    const outline = [];
    if (ids.length > 1) {
      let i = 0;
      for (const s of nb.layout.sections) {
        const idx = ids.indexOf(s.pages[0]);
        if (idx >= 0) outline.push({ title: s.title, index: idx });
        i++;
      }
    }
    const blob = await buildPDF(pages, {
      backgrounds, title, outline,
      liveFrame: editor.surface.frame,
      onprogress: (i, n) => n > 3 && toast(`Building PDF… ${i + 1}/${n}`, 0),
    });
    const how = await savePDF(blob, pdfName(title));
    toast({ saved: 'PDF saved', shared: 'PDF ready', downloaded: 'PDF saved to Downloads', cancelled: 'Cancelled' }[how] || 'Done');
  } catch (e) {
    toast('Export failed: ' + e.message, 5000);
  }
}

// ---------------------------------------------------------------- dialogs

function ask({ title, text = '', value = null, select = null, ok = 'OK' }) {
  const dlg = $('#askdlg');
  $('#asktitle').textContent = title;
  $('#asktext').textContent = text;
  $('#asktext').hidden = !text;
  const input = $('#askinput'), sel = $('#askselect');
  input.hidden = value === null;
  sel.hidden = !select;
  if (value !== null) input.value = value;
  if (select) sel.replaceChildren(...select.map(([v, label]) => Object.assign(document.createElement('option'), { value: v, textContent: label })));
  $('#askok').textContent = ok;
  dlg.showModal();
  if (value !== null) setTimeout(() => input.select(), 50);
  return new Promise((res) => {
    dlg.onclose = () => {
      if (dlg.returnValue !== 'ok') return res(null);
      res(select ? sel.value : value !== null ? input.value.trim() || null : true);
    };
  });
}

function openSettings() {
  closePops();
  const r = $('#pressure');
  r.value = Math.round(settings.pressure * 100);
  const show = () => {
    $('#presval').textContent = `${r.value}%`;
    previewPressure();
  };
  r.oninput = () => {
    settings.pressure = r.value / 100;
    saveSettings();
    show();
  };
  show();
  $('#doubletap').checked = settings.doubleTap;
  $('#fingerdraw').checked = settings.fingerDraw;
  $('#pcinfo').textContent = link
    ? `Paired with ${link.name || new URL(link.base).host}. Notebooks sync whenever you're on the same network; readable PDFs go to the computer's Documents/OpenPad folder.`
    : 'Not paired. Notebooks stay on this iPad until you pair it with a computer running OpenPad.';
  $('#unpairbtn').hidden = !link;
  $('#syncbtn').hidden = !link;
  store.usage().then((u) => {
    if (u) $('#storage').textContent = `Using ${(u.usage / 1048576).toFixed(1)} MB on this device.`;
  });
  $('#settings').showModal();
}

// A sample stroke whose pressure rises and falls, drawn with the setting.
function previewPressure() {
  const c = $('#prespreview');
  const ctx = c.getContext('2d');
  ctx.clearRect(0, 0, c.width, c.height);
  ctx.fillStyle = '#fff';
  ctx.fillRect(0, 0, c.width, c.height);
  const pts = [];
  let prev = null;
  for (let i = 0; i <= 80; i++) {
    const x = 20 + i * 6.5, raw = 0.08 + 0.85 * Math.sin((i / 80) * Math.PI) ** 2;
    prev = shapePressure(raw, settings.pressure, prev);
    pts.push([x, 45 + Math.sin(i / 7) * 18, prev]);
  }
  drawStroke(ctx, { tool: 'pen', color: '#111111', width: 5, pts }, 1);
}

$('#doubletap').onchange = (e) => {
  settings.doubleTap = e.target.checked;
  saveSettings();
};
$('#fingerdraw').onchange = (e) => {
  settings.fingerDraw = e.target.checked;
  saveSettings();
};
$('#pairbtn').onclick = () => {
  $('#settings').close();
  openPair();
};
$('#syncbtn').onclick = () => sync?.run().then(() => sync.flushPDFs()).then(() => toast('Synced'));
$('#unpairbtn').onclick = async () => {
  await store.kvSet('pc', null);
  ws?.close();
  ws = null;
  sync = null;
  link = null;
  setPill('none');
  $('#settings').close();
  syncLiveBadge();
  toast('This iPad forgot the computer. Your notebooks stay here.');
};

function openPair() {
  if (location.protocol === 'http:' && !link) {
    return toast('Open OpenPad on the computer and scan its QR code with the iPad camera.', 6000);
  }
  $('#pairerr').hidden = true;
  $('#pairdlg').showModal();
}
$('#pairgo').onclick = async (e) => {
  e.preventDefault();
  $('#pairerr').hidden = true;
  $('#pairgo').disabled = true;
  try {
    link = await Link.pair($('#pairaddr').value, $('#pairpin').value);
    $('#pairdlg').close();
    toast(`Paired with ${link.name || 'your computer'}. Syncing…`);
    startLink();
  } catch (err) {
    $('#pairerr').textContent = err.message;
    $('#pairerr').hidden = false;
  } finally {
    $('#pairgo').disabled = false;
  }
};

// ---------------------------------------------------------------- invite

let inviteKind = 'w';
async function openInvite() {
  closePops();
  if (!link) return toast('Pair with a computer first: guests connect to it.');
  $('#invitedlg').showModal();
  await refreshInvite();
}

async function refreshInvite(action) {
  let info;
  try {
    info = action
      ? await link.api('/api/guests', { method: 'POST', body: JSON.stringify({ action }), headers: { 'Content-Type': 'application/json' } })
      : await link.api('/api/info');
  } catch (e) {
    $('#invlink').textContent = 'The computer is offline.';
    return;
  }
  const g = info.guests;
  const net = g.internet;
  $('#invnet').checked = net.state === 'on' || net.state === 'starting';
  $('#invnet').disabled = !net.available && net.state !== 'on';
  const url = (net.state === 'on' ? g['i' + inviteKind] : null) || g[inviteKind];
  $('#invlink').textContent = url || 'No network address on the computer.';
  $('#invqr').src = url ? link.url(`/api/qr.svg?k=${encodeURIComponent(link.key)}&for=${net.state === 'on' ? 'i' : ''}${inviteKind}&t=${Date.now()}`) : '';
  $('#invnetinfo').textContent = !net.available ? 'Internet links need cloudflared on the computer (its setup can install it).'
    : net.state === 'starting' ? 'Starting the internet link…'
    : net.state === 'error' ? net.error
    : net.state === 'on' ? 'Internet link is on. Turn it off when the session ends.'
    : 'Uses a free Cloudflare tunnel while it’s on. Traffic is encrypted but passes through Cloudflare.';
  if (net.state === 'starting') setTimeout(() => $('#invitedlg').open && refreshInvite(), 1500);
  $('#invitedlg').dataset.url = url || '';
}
$$('#invkind button').forEach((b) => (b.onclick = () => {
  inviteKind = b.dataset.kind;
  $$('#invkind button').forEach((x) => x.classList.toggle('on', x === b));
  refreshInvite();
}));
$('#invnet').onchange = (e) => refreshInvite(e.target.checked ? 'internet-on' : 'internet-off');
$('#invrotate').onclick = async () => {
  if ((await ask({ title: 'Make new links?', text: 'Everyone using the current links is disconnected.', ok: 'New links' })) === null) return openInvite();
  $('#invitedlg').showModal();
  refreshInvite('rotate');
};
$('#invcopy').onclick = async () => {
  try {
    await navigator.clipboard.writeText($('#invitedlg').dataset.url);
    toast('Link copied');
  } catch {
    toast('Copy the link from the box above');
  }
};
$('#invshare').onclick = () => navigator.share?.({ title: `${current?.title || 'OpenPad'} (live)`, url: $('#invitedlg').dataset.url }).catch(() => {});

// ---------------------------------------------------------------- toolbar

for (const c of COLORS) {
  const b = document.createElement('button');
  b.className = 'swatch' + (c === editor.color ? ' on' : '');
  b.style.setProperty('--c', c);
  b.title = c;
  b.onclick = () => {
    editor.color = c;
    $$('#colors button').forEach((x) => x.classList.toggle('on', x === b));
    if (editor.tool === 'eraser' || editor.tool === 'lasso') {
      if (editor.selection) return editor.selectionAction('color', c);
      setTool('pen');
    }
  };
  $('#colors').append(b);
}

function setTool(t) {
  editor.setTool(t);
  $$('[data-tool]').forEach((b) => b.classList.toggle('on', b.dataset.tool === t));
}
$$('[data-tool]').forEach((b) => (b.onclick = (e) => {
  if (b.dataset.tool === 'shape' && editor.tool === 'shape') {
    e.stopPropagation();
    return togglePop('#shapes');
  }
  setTool(b.dataset.tool);
}));
const SHAPE_ICONS = {
  line: '<path d="M4 20L20 4"/>',
  arrow: '<path d="M4 20L20 4M11 4h9v9"/>',
  rect: '<rect x="4" y="6" width="16" height="12" rx="1"/>',
  ellipse: '<ellipse cx="12" cy="12" rx="9" ry="6.5"/>',
  axes: '<path d="M5 3v16h16M5 3l-2 3M5 3l2 3M21 19l-3-2M21 19l-3 2"/>',
};
$$('[data-shape]').forEach((b) => (b.onclick = () => {
  editor.shape = b.dataset.shape;
  $('#shapeicon').innerHTML = SHAPE_ICONS[editor.shape];
  setTool('shape');
  closePops();
}));
$$('[data-w]').forEach((b) => (b.onclick = () => {
  editor.width = +b.dataset.w;
  $$('[data-w]').forEach((x) => x.classList.toggle('on', x === b));
  if (editor.tool === 'eraser' || editor.tool === 'lasso') setTool('pen');
}));
$('#undo').onclick = () => editor.doUndo();
$('#redo').onclick = () => editor.doRedo();
$('#prev').onclick = () => editor.goto(-1);
$('#next').onclick = () => editor.goto(1);
$('#addpage').onclick = () => editor.addPage();
$('#fitbtn').onclick = () => editor.show(editor.pid, true);
$('#back').onclick = () => closeNotebook();
$('#sidebtn').onclick = () => {
  const side = $('#side');
  side.hidden = !side.hidden;
  document.body.classList.toggle('with-side', !side.hidden);
  editor.layout();
  if (!side.hidden) renderSide();
};
$('#s-addsec').onclick = async () => {
  const title = await ask({ title: 'New section', value: 'Lecture', ok: 'Add' });
  if (title) editor.addSection(title.slice(0, 80));
  renderSide();
};
$('#livebadge').onclick = () => openInvite();

function togglePop(sel) {
  const el = $(sel);
  const show = el.hidden;
  closePops();
  el.hidden = !show;
}
function closePops() {
  $('#menu').hidden = true;
  $('#shapes').hidden = true;
}
$('#menubtn').onclick = (e) => {
  e.stopPropagation();
  togglePop('#menu');
};
document.addEventListener('pointerdown', (e) => {
  if (!e.target.closest('#menu, #menubtn, #shapes, #shapebtn')) closePops();
});

$('#m-import').onclick = () => {
  closePops();
  importTarget = 'notebook';
  $('#file').click();
};
$('#m-export').onclick = async () => {
  closePops();
  const dlg = $('#exportdlg');
  dlg.showModal();
  dlg.onclose = () => {
    if (dlg.returnValue !== 'save') return;
    const what = dlg.querySelector('input[name=what]:checked').value;
    const sec = sectionOf(current, editor.pid);
    if (what === 'page') exportPages(current, [editor.pid], `${current.title} - page ${editor.position().index + 1}`);
    else if (what === 'section') exportPages(current, sec.pages, `${current.title} - ${sec.title}`);
    else exportPages(current, order(current), current.title);
  };
};
$$('[data-paper]').forEach((b) => (b.onclick = () => {
  editor.setPaper(b.dataset.paper);
  renderPager();
}));
$('#m-clear').onclick = () => {
  closePops();
  editor.clearPage();
};
$('#m-delpage').onclick = async () => {
  closePops();
  if (order(current).length <= 1) return toast('A notebook needs at least one page.');
  if ((await ask({ title: 'Delete this page?', ok: 'Delete' })) !== null) editor.deletePage();
};
$('#m-movepage').onclick = async () => {
  closePops();
  const secs = current.layout.sections;
  if (secs.length < 2) return toast('Add another section first (sidebar › + Section).');
  const to = await ask({ title: 'Move this page to', select: secs.map((s) => [s.id, s.title]), ok: 'Move' });
  if (to) editor.movePage(editor.pid, to, 1e9);
};
$('#m-cast').onchange = (e) => {
  cast = e.target.checked;
  localStorage.setItem('openpad.cast', cast ? '1' : '0');
  live.ready = false;
  if (cast) castCurrent();
  syncLiveBadge();
};
$('#m-invite').onclick = openInvite;
$('#m-window').onclick = () => {
  closePops();
  if (!live.ready) return toast('Turn on “Show on the computer” first.');
  ws.send({ t: 'live', action: live.state === 'idle' ? 'start' : 'stop' });
};
$('#m-clearguests').onclick = () => {
  closePops();
  send({ t: 'clearguests', page: editor.pid });
};
$('#m-rename').onclick = async () => {
  closePops();
  const title = await ask({ title: 'Rename notebook', value: current.title, ok: 'Rename' });
  if (!title) return;
  current.title = title.slice(0, 120);
  current.metaT = now();
  onop({ t: 'merge', nb: { id: current.id, title: current.title, size: current.size, metaT: current.metaT, goneP: [], pages: {} } }, { structural: true });
  document.title = `${current.title} · OpenPad`;
};
$('#m-settings').onclick = openSettings;
$('#l-settings').onclick = openSettings;
$('#l-new').onclick = createNotebook;
$('#l-import').onclick = () => {
  importTarget = 'library';
  $('#file').click();
};
$('#pcpill').onclick = () => (link ? sync?.run() : openPair());
$('#file').onchange = (e) => {
  const f = e.target.files[0];
  e.target.value = '';
  if (f) onFile(f);
};

// Keyboard shortcuts (handy with a Magic Keyboard).
document.addEventListener('keydown', (e) => {
  if (!current || e.target.closest?.('input, dialog')) return;
  const mod = e.metaKey || e.ctrlKey;
  if (mod && e.key.toLowerCase() === 'z') {
    e.preventDefault();
    e.shiftKey ? editor.doRedo() : editor.doUndo();
  } else if (e.key === 'ArrowRight' || e.key === 'PageDown') editor.goto(1);
  else if (e.key === 'ArrowLeft' || e.key === 'PageUp') editor.goto(-1);
  else if (e.key === 'e') setTool('eraser');
  else if (e.key === 'p') setTool('pen');
  else if (e.key === 'h') setTool('hl');
  else if (e.key === 's') setTool('lasso');
  else if (e.key === 'l') setTool('shape');
  else if ((e.key === 'Delete' || e.key === 'Backspace') && editor.selection) editor.selectionAction('delete');
});

// ---------------------------------------------------------------- life cycle

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') {
    flushSave();
    sync?.run().then(() => sync?.flushPDFs());
  } else sync?.run();
});
setInterval(() => {
  if (!sync) return;
  store.listNotebooks().then((l) => l.some((n) => n.dirty) && sync.run());
  sync.tickPDFs();
}, 20000);

// The installed app works offline: cache its files.
if ('serviceWorker' in navigator && location.protocol === 'https:') navigator.serviceWorker.register('sw.js').catch(() => {});

editor.syncUndo();
renderLibrary();
startLink();
syncLiveBadge();
// Opening from the computer's link: go straight to the notebook on screen.
if (link && new URLSearchParams(location.search).get('k')) {
  link.api('/api/sync').then(async (r) => {
    if (current || !r.live) return;
    await sync.run();
    if (await store.loadNotebook(r.live)) openNotebook(r.live);
  }).catch(() => {});
}
