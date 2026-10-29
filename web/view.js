// The share window: the live notebook, big and clean for Zoom/Teams/Meet.
// Opened by the computer (bar icon or `openpad`), never by a link.

import { Backgrounds, Surface, buildPDF, pdfInfo, pdfName, savePDF } from './ink.js';
import { socket } from './link.js';
import { applyOp, indexStrokes, mergeInto, normalize, order, sectionOf, sha256Hex } from './model.js';

const $ = (s) => document.querySelector(s);
const $$ = (s) => document.querySelectorAll(s);
const stage = $('#stage');

// ---------------------------------------------------------------- key

// The computer opens this window with a one-time code (#c=...) that is
// swapped for the key and removed from the address bar. The key is kept in
// sessionStorage so a reload works; nothing goes in cookies.
async function getKey() {
  const code = new URLSearchParams(location.hash.slice(1)).get('c');
  if (code) {
    try {
      const r = await fetch('/api/redeem', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ c: code }) });
      if (r.ok) {
        const { k } = await r.json();
        try {
          sessionStorage.setItem('openpad.k', k);
        } catch {}
        history.replaceState(null, '', location.pathname);
        return k;
      }
    } catch {}
    history.replaceState(null, '', location.pathname);
  }
  try {
    return sessionStorage.getItem('openpad.k') || '';
  } catch {
    return '';
  }
}

function showLocked(message) {
  const el = document.createElement('div');
  el.id = 'locked';
  el.innerHTML = '<div class="card"><h1>OpenPad</h1><p></p></div>';
  el.querySelector('p').textContent = message;
  document.body.append(el);
}

// `openpad annotate` on Windows/macOS opens this window with #annotate=1.
const hashArgs = new URLSearchParams(location.hash.slice(1));
const askToAnnotate = hashArgs.get('annotate') === '1';
const askToInvite = hashArgs.get('guests') === '1';
const key = await getKey();
const K = `k=${encodeURIComponent(key)}`;
const api = (path, opts = {}) => fetch(path, { ...opts, headers: { 'X-OpenPad-Key': key, ...(opts.headers || {}) } });
if (!key || !(await api('/api/info').then((r) => r.ok, () => true))) {
  showLocked('This window has no access key. Open it from the OpenPad bar icon, or run: openpad open');
  throw new Error('openpad: no key');
}
const theme = document.createElement('link');
theme.rel = 'stylesheet';
theme.href = `/theme.css?${K}`;
document.head.append(theme);

const backgrounds = new Backgrounds(async (sha) => `/api/asset/${sha}?${K}`);
const surface = new Surface(stage, backgrounds);

let nb = null;
let idx = new Map();
let pid = null;
let pads = 0;
let pairForced = null; // null = automatic, true/false = user toggled
let cursor = null; // {page, x, y}

// View: `fitted` follows the window size; otherwise the user zoomed/panned.
const MARGIN = 24;
const MIN_ZOOM = 0.5; // relative to fit
const MAX_ZOOM = 12;
let fitted = true;
let follow = true;
let liveState = 'idle';
let captureMode = 'native'; // 'browser' on Windows/macOS: this window captures the window itself
let source = null; // the window this share window is capturing (browser mode)

const page = () => nb?.pages[pid] || null;

function setLive(state) {
  liveState = state;
  const b = $('#b-live');
  b.classList.toggle('on', state !== 'idle');
  b.textContent = state === 'idle' ? 'Window' : 'Stop window';
  b.title = state === 'idle' ? 'Annotate a desktop window (W)' : 'Stop the live window (W)';
}

function liveNotice(msg) {
  if (msg.state === 'picking') return 'Choose the window in the picker on your computer…';
  if (msg.state === 'live') return 'The window is live. Draw on it.';
  if (msg.state === 'error') return msg.error || 'Window capture failed';
  return { cancelled: 'Window sharing cancelled', closed: 'The window closed. Its last frame stays on the page.',
    stopped: 'Stopped. The last frame stays on the page.', error: msg.error || 'Window capture stopped' }[msg.reason] || '';
}

const net = socket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws?role=view&${K}`, {
  status(ok) {
    $('#status').className = ok ? 'ok' : 'bad';
    $('#status').title = ok ? 'Connected' : 'Reconnecting…';
  },
  frame: (blob) => surface.pushFrame(blob),
  message(msg) {
    if (msg.t === 'theme') return (theme.href = `/theme.css?${K}&v=${Date.now()}`);
    if (msg.t === 'live') {
      if (msg.state === 'needs-desktop') return showCapturePrompt();
      if (msg.state === 'source-stop') return stopSource(false);
      setLive(msg.state === 'error' ? 'idle' : msg.state);
      const text = liveNotice(msg);
      if (text) toast(text, msg.state === 'picking' ? 0 : 3500);
      return;
    }
    if (msg.t === 'state') {
      captureMode = msg.capture || 'native';
      setLive(msg.live?.state || 'idle');
      if (source && msg.live?.state === 'live') source.confirmed = true;
      if (source?.confirmed && msg.live?.state !== 'live') stopSource(false);
      const samePage = nb && msg.nb.id === nb.id && pid === msg.page;
      nb = normalize(msg.nb);
      idx = indexStrokes(nb);
      pid = msg.page || order(nb)[0];
      pads = msg.pads;
      document.title = `${nb.title} · OpenPad`;
      showPage(!samePage);
      syncGuests(msg.guests);
      return syncPair();
    }
    if (msg.t === 'peers') {
      pads = msg.pads;
      syncGuests(msg.guests);
      return syncPair();
    }
    if (!nb) return;
    if (msg.t === 'cursor') {
      cursor = msg.hide ? null : { page: msg.page, x: msg.x, y: msg.y };
      if (cursor && cursor.page === pid) keepInView(cursor.x, cursor.y);
      return surface.queueLive();
    }
    if (msg.t === 'goto') {
      if (nb.pages[msg.page] && msg.page !== pid) {
        pid = msg.page;
        showPage(true);
      }
      return;
    }
    if (msg.t === 'merge') {
      if (msg.nb.id !== nb.id) return;
      mergeInto(nb, msg.nb);
      idx = indexStrokes(nb);
      if (!nb.pages[pid]) pid = order(nb)[0];
      showPage(false);
      return syncPair();
    }
    const p = applyOp(nb, idx, msg);
    const onPage = p && p.id === pid;
    if (msg.t === 'begin' && onPage) {
      surface.active.set(msg.s.id, idx.get(msg.s.id)[0]);
      surface.queueLive();
    }
    if (msg.t === 'pts' && surface.active.has(msg.id)) {
      const last = msg.pts[msg.pts.length - 1];
      if (last) keepInView(last[0], last[1]);
      surface.queueLive();
    }
    if (msg.t === 'end') {
      const e = idx.get(msg.id);
      if (e && surface.active.has(msg.id)) surface.commit(e[0]);
    }
    if ((msg.t === 'remove' || msg.t === 'restore') && onPage) surface.drawInk();
    if (msg.t !== 'pts') syncPair();
  },
});

// Pen tip / hover cursor so viewers can follow along.
surface.overlay = (ctx, k) => {
  let at = null;
  for (const s of surface.active.values()) {
    const p = s.pts[s.pts.length - 1];
    if (p) at = p;
  }
  if (!at && cursor && cursor.page === pid) at = [cursor.x, cursor.y];
  if (!at) return;
  ctx.save();
  ctx.beginPath();
  ctx.arc(at[0] * k, at[1] * k, Math.max(4, Math.min(14, 5 * k)), 0, Math.PI * 2);
  ctx.fillStyle = 'rgba(230, 60, 60, 0.35)';
  ctx.strokeStyle = 'rgba(230, 60, 60, 0.9)';
  ctx.lineWidth = 1.5;
  ctx.fill();
  ctx.stroke();
  ctx.restore();
};

function showPage(refit = true) {
  surface.active.clear();
  if (refit || fitted) fit();
  surface.setPage(page());
  const ids = order(nb);
  const i = ids.indexOf(pid);
  const sec = sectionOf(nb, pid);
  $('#pageno').textContent = nb.layout.sections.length > 1 && sec
    ? `${sec.title.slice(0, 18)} · ${sec.pages.indexOf(pid) + 1}/${sec.pages.length}` : `${i + 1} / ${ids.length}`;
  $('#b-prev').disabled = i <= 0;
  $('#b-next').disabled = i >= ids.length - 1;
}

function gotoPage(delta) {
  if (!nb) return;
  const ids = order(nb);
  const i = ids.indexOf(pid) + delta;
  if (i < 0 || i >= ids.length) return;
  pid = ids[i];
  net.send({ t: 'goto', page: pid });
  showPage(true);
}

// ---------------------------------------------------------------- zoom & pan

const fitScale = () => surface.fitScale(page(), MARGIN);

function fit() {
  fitted = true;
  surface.fit(page(), MARGIN);
  syncZoomLabel();
}

let redrawQueued = false;
function queueRedraw() {
  if (redrawQueued) return;
  redrawQueued = true;
  requestAnimationFrame(() => {
    redrawQueued = false;
    surface.redraw();
  });
}

function setView(s, x, y) {
  const f = fitScale();
  const p = page();
  if (!p) return;
  s = Math.min(f * MAX_ZOOM, Math.max(f * MIN_ZOOM, s));
  // Keep at least a sliver of the page on screen.
  const keep = 80;
  x = Math.min(surface.cw - keep, Math.max(keep - p.w * s, x));
  y = Math.min(surface.ch - keep, Math.max(keep - p.h * s, y));
  surface.view = { s, x, y };
  fitted = false;
  syncZoomLabel();
  queueRedraw();
}

function zoomAt(cx, cy, factor) {
  if (!nb) return;
  const v = surface.view;
  const s = Math.min(fitScale() * MAX_ZOOM, Math.max(fitScale() * MIN_ZOOM, v.s * factor));
  const r = s / v.s;
  setView(s, cx - (cx - v.x) * r, cy - (cy - v.y) * r);
}

const zoomCenter = (factor) => zoomAt(surface.cw / 2, surface.ch / 2, factor);

function syncZoomLabel() {
  const pct = Math.round((surface.view.s / fitScale()) * 100);
  $('#b-zoom').textContent = fitted ? 'Fit' : `${pct}%`;
  $('#b-follow').hidden = fitted;
  document.body.classList.toggle('zoomed', !fitted);
}

// While zoomed in, slide the view to keep the pen in sight.
let followAnim = 0;
function keepInView(px, py) {
  if (fitted || !follow || dragging) return;
  const v = surface.view;
  const sx = v.x + px * v.s, sy = v.y + py * v.s;
  const mx = surface.cw * 0.15, my = surface.ch * 0.15;
  let dx = 0, dy = 0;
  if (sx < mx || sx > surface.cw - mx) dx = surface.cw / 2 - sx;
  if (sy < my || sy > surface.ch - my) dy = surface.ch / 2 - sy;
  if (!dx && !dy) return;
  const target = { x: v.x + dx, y: v.y + dy };
  cancelAnimationFrame(followAnim);
  const step = () => {
    const c = surface.view;
    const nx = c.x + (target.x - c.x) * 0.25, ny = c.y + (target.y - c.y) * 0.25;
    setView(c.s, nx, ny);
    if (Math.abs(target.x - nx) + Math.abs(target.y - ny) > 1) followAnim = requestAnimationFrame(step);
  };
  followAnim = requestAnimationFrame(step);
}

// Mouse wheel zooms at the pointer; a touchpad's two-finger scroll pans and
// its pinch (reported as ctrl+wheel) zooms.
stage.addEventListener('wheel', (e) => {
  e.preventDefault();
  if (!nb) return;
  const r = stage.getBoundingClientRect();
  const cx = e.clientX - r.left, cy = e.clientY - r.top;
  const lines = e.deltaMode === 1;
  const mouseWheel = lines || (e.deltaX === 0 && Math.abs(e.deltaY) >= 40 && Number.isInteger(e.deltaY));
  if (e.ctrlKey) zoomAt(cx, cy, Math.exp(-e.deltaY * 0.01));
  else if (mouseWheel) {
    const notches = Math.min(4, Math.max(1, Math.abs(e.deltaY) / (lines ? 3 : 100)));
    zoomAt(cx, cy, Math.pow(e.deltaY < 0 ? 1.18 : 1 / 1.18, notches));
  } else setView(surface.view.s, surface.view.x - e.deltaX, surface.view.y - e.deltaY);
  wake();
}, { passive: false });

// Grab and drag to move around.
let dragging = null;
stage.addEventListener('pointerdown', (e) => {
  if ((e.button !== 0 && e.button !== 1) || !nb) return;
  cancelAnimationFrame(followAnim);
  dragging = { id: e.pointerId, x: e.clientX, y: e.clientY, vx: surface.view.x, vy: surface.view.y };
  try {
    stage.setPointerCapture(e.pointerId);
  } catch {}
  document.body.classList.add('dragging');
});
stage.addEventListener('pointermove', (e) => {
  if (!dragging || e.pointerId !== dragging.id) return;
  const dx = e.clientX - dragging.x, dy = e.clientY - dragging.y;
  if (fitted && Math.abs(dx) + Math.abs(dy) < 3) return;
  setView(surface.view.s, dragging.vx + dx, dragging.vy + dy);
});
const endDrag = (e) => {
  if (!dragging || e.pointerId !== dragging.id) return;
  dragging = null;
  document.body.classList.remove('dragging');
};
stage.addEventListener('pointerup', endDrag);
stage.addEventListener('pointercancel', endDrag);
stage.addEventListener('dblclick', (e) => {
  if (!nb) return;
  if (fitted) {
    const r = stage.getBoundingClientRect();
    zoomAt(e.clientX - r.left, e.clientY - r.top, 2);
  } else {
    fit();
    surface.redraw();
  }
});

// ---------------------------------------------------------------- pairing card

let infoLoaded = 0;
async function loadInfo(force = false) {
  if (!force && Date.now() - infoLoaded < 20000) return;
  try {
    const info = await (await api('/api/info')).json();
    const url = info.urls[0];
    $('#url').textContent = url || 'No Wi-Fi address found. Connect to a network, then restart OpenPad.';
    $('#qr').hidden = !url;
    if (url) $('#qr').src = `/api/qr.svg?${K}&for=app&t=${Date.now()}`;
    $('#setupqr').src = `/api/qr.svg?${K}&for=setup&t=${Date.now()}`;
    const p = await (await api('/api/pairing')).json();
    $('#pinaddr').textContent = p.addresses[0] || '—';
    $('#pincode').textContent = p.pin;
    infoLoaded = Date.now();
  } catch {}
}

function syncPair() {
  const empty = nb && Object.values(nb.pages).every((p) => !p.strokes.length && !p.bg) && order(nb).length <= 1;
  const show = pairForced ?? (pads === 0 && empty);
  $('#pair').hidden = !show;
  if (show) loadInfo();
}
$$('#pairtabs button').forEach((b) => (b.onclick = () => {
  $$('#pairtabs button').forEach((x) => x.classList.toggle('on', x === b));
  $$('[data-pane]').forEach((p) => (p.hidden = p.dataset.pane !== b.dataset.tab));
  loadInfo(true);
}));
setInterval(() => !$('#pair').hidden && loadInfo(true), 30000); // the PIN changes every 10 minutes

// ---------------------------------------------------------------- guests

let gkind = 'w';
async function guestAction(action) {
  const r = await api('/api/guests', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(action ? { action } : {}),
  });
  renderGuests((await r.json()).guests);
}
function renderGuests(g) {
  const net = g.internet;
  const internet = net.state === 'on';
  const url = (internet ? g['i' + gkind] : null) || g[gkind];
  $('#glink').textContent = url || 'No network address';
  $('#gqr').src = url ? `/api/qr.svg?${K}&for=${internet ? 'i' : ''}${gkind}&t=${Date.now()}` : '';
  $('#gnet').textContent = internet ? 'Internet link: on' : net.state === 'starting' ? 'Internet link: starting…' : 'Internet link: off';
  $('#gnet').classList.toggle('on', internet);
  $('#gnetinfo').textContent = !net.available ? 'Internet links need cloudflared (setup can install it). Without it, guests must be on this Wi-Fi.'
    : net.state === 'error' ? net.error
    : internet ? 'Anyone with this link can join from anywhere. Turn it off when you finish.'
    : 'Off: only people on this Wi-Fi can join. On: a free Cloudflare tunnel (encrypted, but through Cloudflare).';
  $('#guests').dataset.url = url || '';
  $('#guests').dataset.net = net.state;
  if (net.state === 'starting') setTimeout(() => !$('#guests').hidden && guestAction(), 1500);
}
function syncGuests(n) {
  if (typeof n === 'number') $('#gcount').textContent = n ? `${n} guest${n > 1 ? 's' : ''} connected` : 'No guests connected';
  $('#b-guests').textContent = n ? `Invite (${n})` : 'Invite';
}
function toggleGuests() {
  const el = $('#guests');
  el.hidden = !el.hidden;
  if (!el.hidden) {
    $('#pair').hidden = true;
    guestAction();
  }
}
$$('#gkind button').forEach((b) => (b.onclick = () => {
  gkind = b.dataset.kind;
  $$('#gkind button').forEach((x) => x.classList.toggle('on', x === b));
  guestAction();
}));
$('#gcopy').onclick = async () => {
  try {
    await navigator.clipboard.writeText($('#guests').dataset.url);
    toast('Link copied');
  } catch {
    toast('Select the link and copy it');
  }
};
$('#gnet').onclick = () => guestAction($('#guests').dataset.net === 'on' || $('#guests').dataset.net === 'starting' ? 'internet-off' : 'internet-on');
$('#grotate').onclick = () => confirm('Make new links? Everyone using the current ones is disconnected.') && guestAction('rotate');
$('#guests').onclick = (e) => e.target === $('#guests') && toggleGuests();

// ---------------------------------------------------------------- controls

let toastTimer = 0;
function toast(text, ms = 2500) {
  const t = $('#toast');
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toastTimer);
  if (ms) toastTimer = setTimeout(() => (t.hidden = true), ms);
}

// A PDF dropped or opened here becomes a new section of the live notebook.
async function openPDF(f) {
  if (!f || !nb) return;
  toast(`Opening ${f.name}…`, 0);
  try {
    const bytes = new Uint8Array(await f.arrayBuffer());
    if (String.fromCharCode(...bytes.slice(0, 5)) !== '%PDF-') throw new Error('That file is not a PDF');
    const sizes = await pdfInfo(bytes);
    const sha = await sha256Hex(bytes);
    const r = await api(`/api/asset/${sha}`, { method: 'PUT', body: bytes });
    if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || 'upload failed');
    net.send({ t: 'addpdf', sha, sizes, name: f.name });
    toast(`Added ${f.name} (${sizes.length} pages)`);
    pairForced = false;
  } catch (err) {
    toast(err.message, 5000);
  }
}

async function save() {
  if (!nb) return;
  toast('Building PDF…', 0);
  try {
    const ids = order(nb);
    const outline = ids.length > 1 ? nb.layout.sections.filter((s) => s.pages.length).map((s) => ({ title: s.title, index: ids.indexOf(s.pages[0]) })) : [];
    const blob = await buildPDF(ids.map((id) => nb.pages[id]), { backgrounds, title: nb.title, outline, liveFrame: surface.frame });
    const how = await savePDF(blob, pdfName(nb.title));
    toast({ saved: 'PDF saved', downloaded: 'Saved to your Downloads folder', cancelled: 'Cancelled' }[how] || 'Done');
  } catch (err) {
    toast('Export failed: ' + err.message, 5000);
  }
}

function togglePair() {
  pairForced = $('#pair').hidden;
  $('#guests').hidden = true;
  syncPair();
}

function toggleLive() {
  if (source) return stopSource(true);
  if (liveState !== 'idle') return net.send({ t: 'live', action: 'stop' });
  if (captureMode === 'browser') return startSource(); // needs this click for the picker
  net.send({ t: 'live', action: 'start' });
}

// ---------------------------------------------------------------- browser window capture
// Windows and macOS have no screen-share portal OpenPad can use, so this window
// captures the chosen window with the browser's own picker and streams JPEG
// frames to the server, which relays them to the iPad.

const MAX_W = 1600;
const FPS = 15;

function showCapturePrompt() {
  if (source || captureMode !== 'browser') return;
  $('#capture-prompt').hidden = false;
}

async function startSource() {
  $('#capture-prompt').hidden = true;
  if (!navigator.mediaDevices?.getDisplayMedia) return toast('This browser cannot capture windows. Use Chrome or Edge.', 5000);
  let stream;
  try {
    stream = await navigator.mediaDevices.getDisplayMedia({
      video: { displaySurface: 'window', frameRate: { ideal: FPS, max: FPS } },
      audio: false,
      selfBrowserSurface: 'exclude',
      surfaceSwitching: 'exclude',
    });
  } catch (e) {
    return toast(e.name === 'NotAllowedError' ? 'Window sharing cancelled' : 'Could not capture the window: ' + e.message, 4000);
  }
  const track = stream.getVideoTracks()[0];
  const st = track.getSettings();
  source = { stream, track, w: st.width || 1280, h: st.height || 720, last: 0, busy: false, stopped: false, confirmed: false };
  track.addEventListener('ended', () => stopSource(true)); // "Stop sharing" in the browser
  net.send({ t: 'live', action: 'source', w: source.w, h: source.h });
  pump(source);
}

async function pump(src) {
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d');
  const send = async (image, w, h) => {
    if (!w || !h) return;
    if (w !== src.w || h !== src.h) {
      src.w = w;
      src.h = h;
      net.send({ t: 'live', action: 'resize', w, h });
    }
    const k = Math.min(1, MAX_W / w);
    const cw = Math.max(2, Math.round(w * k) & ~1), ch = Math.max(2, Math.round(h * k) & ~1);
    if (canvas.width !== cw || canvas.height !== ch) {
      canvas.width = cw;
      canvas.height = ch;
    }
    ctx.drawImage(image, 0, 0, cw, ch);
    const blob = await new Promise((res) => canvas.toBlob(res, 'image/jpeg', 0.72));
    // Skip frames rather than queue them if the connection is backed up.
    if (blob && !src.stopped && net.bufferedAmount() < 2_000_000) net.sendBinary(blob);
  };
  if ('MediaStreamTrackProcessor' in window) {
    // Frames arrive as the window changes, even while this window is in the background.
    const reader = new MediaStreamTrackProcessor({ track: src.track }).readable.getReader();
    src.reader = reader;
    while (!src.stopped) {
      let res;
      try {
        res = await reader.read();
      } catch {
        break;
      }
      if (res.done) break;
      const frame = res.value;
      const t = performance.now();
      if (!src.busy && t - src.last >= 1000 / FPS - 4) {
        src.last = t;
        src.busy = true;
        try {
          await send(frame, frame.displayWidth, frame.displayHeight);
        } catch {}
        src.busy = false;
      }
      frame.close();
    }
  } else {
    const video = document.createElement('video');
    video.muted = true;
    video.playsInline = true;
    video.srcObject = src.stream;
    await video.play().catch(() => {});
    src.timer = setInterval(async () => {
      if (src.busy || src.stopped) return;
      src.busy = true;
      try {
        await send(video, video.videoWidth, video.videoHeight);
      } catch {}
      src.busy = false;
    }, 1000 / FPS);
  }
}

function stopSource(notify) {
  if (!source) return;
  const src = source;
  source = null;
  src.stopped = true;
  src.reader?.cancel().catch(() => {});
  clearInterval(src.timer);
  src.stream.getTracks().forEach((t) => t.stop());
  if (notify) net.send({ t: 'live', action: 'stop' });
}

function toggleFollow() {
  follow = !follow;
  $('#b-follow').classList.toggle('on', follow);
  toast(follow ? 'Following the pen' : 'Not following the pen', 1200);
}

function fullscreen() {
  if (document.fullscreenElement) document.exitFullscreen();
  else document.documentElement.requestFullscreen().catch(() => {});
}

function resetZoom() {
  fit();
  surface.redraw();
}

$('#b-prev').onclick = () => gotoPage(-1);
$('#b-next').onclick = () => gotoPage(1);
$('#b-zin').onclick = () => zoomCenter(1.25);
$('#b-zout').onclick = () => zoomCenter(1 / 1.25);
$('#b-zoom').onclick = resetZoom;
$('#b-follow').onclick = toggleFollow;
$('#b-qr').onclick = togglePair;
$('#b-guests').onclick = toggleGuests;
$('#b-live').onclick = toggleLive;
$('#b-choose').onclick = startSource;
$('#b-choose-cancel').onclick = () => ($('#capture-prompt').hidden = true);
$('#b-pdf').onclick = () => $('#file').click();
$('#b-export').onclick = save;
$('#b-full').onclick = fullscreen;
$('#file').onchange = (e) => {
  openPDF(e.target.files[0]);
  e.target.value = '';
};
$('#pair').onclick = (e) => {
  if (e.target === $('#pair')) togglePair();
};

document.addEventListener('keydown', (e) => {
  if (e.ctrlKey || e.metaKey || e.altKey) return;
  const k = e.key.toLowerCase();
  if (k === 'q') togglePair();
  else if (k === 'i') toggleGuests();
  else if (k === 'f') fullscreen();
  else if (k === 'o') $('#file').click();
  else if (k === 's') save();
  else if (k === 'l') toggleFollow();
  else if (k === 'w') toggleLive();
  else if (k === '0') resetZoom();
  else if (k === '+' || k === '=') zoomCenter(1.25);
  else if (k === '-' || k === '_') zoomCenter(1 / 1.25);
  else if (k === 'arrowright' || k === 'pagedown' || k === ' ') gotoPage(1);
  else if (k === 'arrowleft' || k === 'pageup') gotoPage(-1);
  else if (k === 'escape' && !$('#capture-prompt').hidden) $('#capture-prompt').hidden = true;
  else if (k === 'escape' && !$('#guests').hidden) toggleGuests();
  else if (k === 'escape' && !$('#pair').hidden) togglePair();
  else return;
  e.preventDefault();
});

// Hide the controls and cursor when the mouse is idle so screen shares stay clean.
let idleTimer = 0;
function wake() {
  document.body.classList.add('awake');
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => document.body.classList.remove('awake'), 2200);
}
document.addEventListener('mousemove', wake);

// Drag and drop a PDF onto the window.
let dragDepth = 0;
const hasFiles = (e) => [...(e.dataTransfer?.types || [])].includes('Files');
document.addEventListener('dragenter', (e) => {
  if (!hasFiles(e)) return;
  e.preventDefault();
  dragDepth++;
  $('#drop').hidden = false;
});
document.addEventListener('dragleave', (e) => {
  if (!hasFiles(e)) return;
  if (--dragDepth <= 0) $('#drop').hidden = true;
});
document.addEventListener('dragover', (e) => e.preventDefault());
document.addEventListener('drop', (e) => {
  e.preventDefault();
  dragDepth = 0;
  $('#drop').hidden = true;
  const f = [...(e.dataTransfer?.files || [])].find((f) => f.type === 'application/pdf' || /\.pdf$/i.test(f.name));
  if (f) openPDF(f);
  else toast('That is not a PDF');
});

function layout() {
  const before = { w: surface.cw, h: surface.ch };
  surface.resize();
  if (!nb) return;
  if (fitted) return showPage(true);
  // Keep the same point centered when the window changes size.
  const v = surface.view;
  setView(v.s, v.x + (surface.cw - before.w) / 2, v.y + (surface.ch - before.h) / 2);
}
new ResizeObserver(() => {
  const r = stage.getBoundingClientRect();
  if (r.width && r.height && (r.width !== surface.cw || r.height !== surface.ch)) layout();
}).observe(stage);
layout();
if (askToAnnotate) {
  captureMode = 'browser';
  showCapturePrompt();
}
if (askToInvite) toggleGuests();
