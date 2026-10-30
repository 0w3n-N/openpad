// Guest page: the presenter's live notebook, from a link they sent. "Draw"
// links can add ink (and erase their own); "view" links only watch. Anyone
// can save pages as a PDF.

import { Backgrounds, COLORS, buildPDF, drawStroke, pdfName, savePDF } from './ink.js';
import { Editor } from './editor.js';
import { PROTOCOL, socket } from './link.js';
import { fitToolbar } from './ui.js';
import { mergeInto, newId, normalize, order, sectionOf } from './model.js';

const $ = (s) => document.querySelector(s);
const $$ = (s) => document.querySelectorAll(s);

const params = new URLSearchParams(location.hash.slice(1));
const kind = params.has('w') ? 'w' : 'v';
const token = params.get(kind) || '';
let me = '';
try {
  me = localStorage.getItem('openpad.me') || '';
  if (!/^[A-Za-z0-9_-]{6,40}$/.test(me)) localStorage.setItem('openpad.me', (me = newId()));
} catch {
  me = newId();
}
const q = `g=${encodeURIComponent(token)}`;

let toastTimer = 0;
function toast(text, ms = 2500) {
  const t = $('#toast');
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toastTimer);
  if (ms) toastTimer = setTimeout(() => (t.hidden = true), ms);
}

if (!token) {
  document.body.innerHTML = '<div id="locked"><div class="card"><h1>OpenPad</h1><p>This link is incomplete. Ask the presenter to send it again.</p></div></div>';
  throw new Error('no token');
}

const theme = document.createElement('link');
theme.rel = 'stylesheet';
theme.href = `/theme.css?${q}`;
document.head.append(theme);

const backgrounds = new Backgrounds(async (sha) => `/api/asset/${sha}?${q}`);
const settings = { pressure: 0.35, doubleTap: false, fingerDraw: false };
let follow = true;
let nb = null;
let presenterPage = null;
let canWrite = kind === 'w';

const editor = new Editor($('#stage'), {
  backgrounds,
  settings,
  toast,
  canDraw: canWrite,
  canEdit: false,
  by: null,
  onop: (msg) => {
    if (msg.t === 'goto') {
      // Browsing on your own: stop following until you tap Follow.
      if (msg.page !== presenterPage) setFollow(false);
      return;
    }
    if (msg.t !== 'merge') net.send(msg);
  },
  onpage: () => renderPager(),
});
editor.syncUndo = () => {
  $('#undo').disabled = !editor.undo.length;
  $('#redo').disabled = !editor.redo.length;
};
editor.onzoom = (z) => ($('#fitbtn').hidden = !z);

const net = socket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws?${q}&v=${PROTOCOL}&me=${encodeURIComponent(me)}`, {
  status(ok) {
    $('#dot').className = ok ? 'ok' : 'bad';
  },
  frame: (b) => editor.surface.pushFrame(b),
  message(msg) {
    if (msg.t === 'theme') {
      theme.href = `/theme.css?${q}&v=${Date.now()}`;
      return;
    }
    if (msg.t === 'state') {
      canWrite = msg.write;
      editor.canDraw = canWrite;
      editor.by = msg.by;
      document.body.classList.toggle('viewonly', !canWrite);
      presenterPage = msg.page;
      $('#waiting').hidden = !msg.placeholder;
      const fresh = normalize(msg.nb);
      if (nb && nb.id === fresh.id) {
        mergeInto(nb, fresh);
        editor.refresh();
      } else {
        nb = fresh;
        editor.setNotebook(nb, msg.page);
      }
      if (follow && msg.page && msg.page !== editor.pid) editor.show(msg.page, true);
      document.title = msg.placeholder ? 'OpenPad · live notes' : `${nb.title} · OpenPad`;
      return renderPager();
    }
    if (!nb) return;
    if (msg.t === 'goto') {
      presenterPage = msg.page;
      if (follow) editor.show(msg.page, true);
      return renderPager();
    }
    if (msg.t === 'merge') {
      if (msg.nb.id !== nb.id) return;
      mergeInto(nb, msg.nb);
      editor.refresh();
      return renderPager();
    }
    if (msg.t === 'cursor') {
      cursor = msg.hide ? null : msg;
      return editor.surface.queueLive();
    }
    if (msg.t === 'preview') {
      const p = previews.get(msg.id) || { page: msg.page, pts: [], color: msg.color, width: msg.width, tool: msg.tool };
      if (msg.end) previews.delete(msg.id);
      else {
        p.pts.push(...msg.pts);
        p.t = Date.now();
        previews.set(msg.id, p);
      }
      return editor.surface.queueLive();
    }
    if (['begin', 'pts', 'end', 'remove', 'restore'].includes(msg.t)) editor.applyRemote(msg);
  },
}, { queueOffline: true });

// The presenter's pen, so you can follow along, and strokes they're still drawing.
let cursor = null;
const previews = new Map();
editor.extraOverlay = (ctx, k) => {
  for (const [id, p] of previews) {
    if (Date.now() - p.t > 4000) previews.delete(id);
    else if (p.page === editor.pid) drawStroke(ctx, { ...p, id }, k);
  }
  if (!cursor || cursor.page !== editor.pid) return;
  ctx.beginPath();
  ctx.arc(cursor.x * k, cursor.y * k, Math.max(4, Math.min(14, 5 * k)), 0, Math.PI * 2);
  ctx.fillStyle = 'rgba(230, 60, 60, 0.35)';
  ctx.strokeStyle = 'rgba(230, 60, 60, 0.9)';
  ctx.lineWidth = 1.5;
  ctx.fill();
  ctx.stroke();
};

function setFollow(on) {
  follow = on;
  $('#followbtn').classList.toggle('on', on);
  if (on && presenterPage && nb?.pages[presenterPage]) editor.show(presenterPage, true);
}

function renderPager() {
  if (!nb || !editor.pid) return;
  const pos = editor.position();
  $('#pageno').textContent = `${pos.index + 1} / ${pos.count}`;
  $('#prev').disabled = pos.index <= 0;
  $('#next').disabled = pos.index >= pos.count - 1;
}

for (const c of COLORS) {
  const b = document.createElement('button');
  b.className = 'swatch' + (c === editor.color ? ' on' : '');
  b.style.setProperty('--c', c);
  b.onclick = () => {
    editor.color = c;
    $('#stylebtn').style.setProperty('--c', c);
    $$('#colors button').forEach((x) => x.classList.toggle('on', x === b));
    if (editor.tool === 'eraser' || editor.tool === 'hand') setTool('pen');
  };
  $('#colors').append(b);
}
function setTool(t) {
  editor.setTool(t);
  $$('[data-tool]').forEach((b) => b.classList.toggle('on', b.dataset.tool === t));
}
$$('[data-tool]').forEach((b) => (b.onclick = () => setTool(b.dataset.tool)));
$$('[data-w]').forEach((b) => (b.onclick = () => {
  editor.width = +b.dataset.w;
  $$('[data-w]').forEach((x) => x.classList.toggle('on', x === b));
}));
$('#undo').onclick = () => editor.doUndo();
$('#redo').onclick = () => editor.doRedo();
$('#prev').onclick = () => editor.goto(-1);
$('#next').onclick = () => editor.goto(1);
$('#followbtn').onclick = () => setFollow(!follow);
$('#fitbtn').onclick = () => editor.show(editor.pid, true);
$('#savehint').textContent = navigator.maxTouchPoints > 1
  ? 'On an iPad or phone, choose Save to Files and pick a folder.'
  : window.showSaveFilePicker ? 'You choose the folder and file name next.' : 'It goes to your Downloads folder (or wherever your browser asks).';

$('#savebtn').onclick = () => {
  if (!nb) return;
  const dlg = $('#exportdlg');
  dlg.showModal();
  dlg.onclose = async () => {
    if (dlg.returnValue !== 'save') return;
    const what = dlg.querySelector('input[name=what]:checked').value;
    const sec = sectionOf(nb, editor.pid);
    const ids = what === 'page' ? [editor.pid] : what === 'section' ? sec.pages : order(nb);
    const title = what === 'page' ? `${nb.title} - page ${editor.position().index + 1}` : what === 'section' ? `${nb.title} - ${sec.title}` : nb.title;
    toast('Building PDF…', 0);
    try {
      const blob = await buildPDF(ids.map((id) => nb.pages[id]), { backgrounds, title, liveFrame: editor.surface.frame });
      const how = await savePDF(blob, pdfName(title));
      toast({ saved: 'PDF saved', shared: 'PDF ready', downloaded: 'PDF downloaded', cancelled: 'Cancelled' }[how] || 'Done');
    } catch (e) {
      toast('Could not build the PDF: ' + e.message, 5000);
    }
  };
};

document.addEventListener('keydown', (e) => {
  if (e.target.closest?.('dialog')) return;
  const mod = e.metaKey || e.ctrlKey;
  if (mod && e.key.toLowerCase() === 'z' && canWrite) {
    e.preventDefault();
    e.shiftKey ? editor.doRedo() : editor.doUndo();
  } else if (e.key === 'ArrowRight' || e.key === 'PageDown') editor.goto(1);
  else if (e.key === 'ArrowLeft' || e.key === 'PageUp') editor.goto(-1);
  else if (canWrite && e.key === 'e') setTool('eraser');
  else if (canWrite && e.key === 'p') setTool('pen');
  else if (canWrite && e.key === 'h') setTool('hl');
});

if (!canWrite) setTool('hand');
document.addEventListener('dblclick', (e) => e.preventDefault());
$('#stylebtn').style.setProperty('--c', editor.color);
fitToolbar({
  button: $('#stylebtn'),
  pop: $('#stylepop'),
  levels: [[640, [$('#tools'), $('#undogroup')]], [1000, [$('#colors'), $('#widths')]]],
});
editor.syncUndo();
editor.layout();
