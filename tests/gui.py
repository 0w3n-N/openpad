#!/usr/bin/env python3
"""The web pages in a real WebKit (Safari's engine), with real key presses.

For what only shows up in a browser: dialogs, the keyboard, the toolbar's fit.
Runs a real server on a free port with throwaway data directories; touches
nothing in your home folder, and opens no window. Needs WebKitGTK (Debian,
Ubuntu: gir1.2-webkit2-4.1) and a display (xvfb-run works); skipped without them.

    python3 -B tests/gui.py
"""

import json
import os
import socket
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = tempfile.mkdtemp(prefix="openpad-gui-")
for name, sub in (("XDG_DATA_HOME", "data"), ("XDG_RUNTIME_DIR", "run"), ("XDG_STATE_HOME", "state"), ("OPENPAD_NOTES", "notes")):
    os.environ[name] = os.path.join(TMP, sub)
os.makedirs(os.environ["XDG_RUNTIME_DIR"], mode=0o700)
# Software drawing: there may be no GPU, and nothing is shown anyway.
os.environ["WEBKIT_DISABLE_COMPOSITING_MODE"] = "1"
os.environ["WEBKIT_DISABLE_DMABUF_RENDERER"] = "1"
sys.path.insert(0, ROOT)

try:
    import gi

    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    gi.require_version("WebKit2", "4.1")
    from gi.repository import Gdk, GLib, Gtk, WebKit2
except (ImportError, ValueError) as e:
    print(f"SKIP WebKitGTK not available ({e})")
    sys.exit(0)
if not Gtk.init_check()[0]:
    print("SKIP no display (try: xvfb-run -a python3 -B tests/gui.py)")
    sys.exit(0)

from openpad import notebook as N  # noqa: E402
from openpad.server import OpenPadServer  # noqa: E402

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail and not cond else ""))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def stroke(i):
    return {"id": N.new_id(), "z": time.time() * 1000 + i, "tool": "pen", "color": "#1f5fd6", "width": 3.5,
            "pts": [[100.0 + k * 10, 200.0 + i * 40, 0.5] for k in range(30)]}


def book(title, sections):
    """A notebook, last changed an hour ago (so "just now" stands out)."""
    t = N.now_ms() - 3600_000
    layout, pages = [], {}
    for name, count in sections:
        sec = N.new_id()
        ids = []
        for i in range(count):
            p = N.blank_page(sec, "letter", "lines", t)
            p["strokes"] = [stroke(i)]
            pages[p["id"]] = p
            ids.append(p["id"])
        layout.append({"id": sec, "title": name, "pages": ids})
    return N.finish({"v": 1, "id": N.new_id(), "title": title, "size": "letter", "folder": "", "metaT": t, "created": t,
                     "layout": {"t": t, "sections": layout}, "goneP": [], "pages": pages})


PORT = free_port()
srv = OpenPadServer("127.0.0.1", PORT)
KEY = srv.token
for nb in (book("Toolbar", [("Ch 1", 3), ("Ch 2", 1)]), book("Long names", [("Laplace transforms", 3), ("Homework", 1)]),
           book("Delete pages", [("Notes", 4)]), book("Delete me", [("Notes", 1)]),
           book("Only opened", [("Notes", 2)]), book("Really edited", [("Notes", 2)])):
    srv.store.put(nb)
srv.save()
threading.Thread(target=srv.serve_forever, daemon=True).start()
APP = f"/app?k={KEY}"

# What every script can use: key() presses a real key, until() waits for something.
PRELUDE = """
const $ = (s) => document.querySelector(s);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const key = (k) => { webkit.messageHandlers.key.postMessage(k); return sleep(300); };
const until = async (fn, ms = 15000) => {
  for (const end = Date.now() + ms; Date.now() < end; await sleep(50)) if (fn()) return true;
  throw new Error('timed out waiting for ' + fn);
};
const card = (title) => [...document.querySelectorAll('.book')].find((b) => b.querySelector('strong').textContent === title);
const titles = () => [...document.querySelectorAll('.book strong')].map((e) => e.textContent);
const library = async () => {
  await until(() => document.querySelector('.book') && !$('#pcpill').dataset.state?.includes('syncing'));
  if ($('#library').hidden) { $('#back').click(); await until(() => !$('#library').hidden); }
  await sleep(300);
};
const openBook = async (title) => {
  await library();
  card(title).querySelector('.cover').click();
  await until(() => !$('#editor').hidden && document.title.startsWith(title));
  await sleep(600); // past the notebook's first state from the computer
};
"""


def page(path, script, size=(1180, 820)):
    """Load a page in a fresh, private WebKit; run an async script there; return what it returns."""
    win = Gtk.OffscreenWindow()
    win.set_default_size(*size)
    view = WebKit2.WebView.new_with_context(WebKit2.WebContext.new_ephemeral())
    view.set_size_request(*size)
    win.add(view)
    win.show_all()
    view.grab_focus()
    out = {}

    def press(name):
        display = Gdk.Display.get_default()
        keyval = Gdk.keyval_from_name(name)
        found, keys = Gdk.Keymap.get_for_display(display).get_entries_for_keyval(keyval)
        for kind in (Gdk.EventType.KEY_PRESS, Gdk.EventType.KEY_RELEASE):
            ev = Gdk.Event.new(kind)
            ev.key.window = view.get_window()
            ev.key.time = Gdk.CURRENT_TIME
            ev.key.keyval = keyval
            ev.key.hardware_keycode = keys[0].keycode if found and keys else 0
            ev.set_device(display.get_default_seat().get_keyboard())
            view.event(ev)

    handlers = view.get_user_content_manager()
    handlers.register_script_message_handler("key")
    handlers.connect("script-message-received::key", lambda _m, msg: press(msg.get_js_value().to_string()))

    def done(v, res, _):
        try:
            text = v.call_async_javascript_function_finish(res).to_string()
            out["value"] = json.loads(text) if text and text != "undefined" else None
        except GLib.Error as e:
            out["error"] = e.message
        Gtk.main_quit()

    def loaded(v, event):
        if event == WebKit2.LoadEvent.FINISHED and not out.get("started"):
            out["started"] = True
            body = PRELUDE + "return JSON.stringify(await (async () => {\n" + script + "\n})());"
            v.call_async_javascript_function(body, -1, None, None, None, None, done, None)

    def failed(_v, _e, uri, err):
        out["error"] = f"{uri}: {err.message}"
        Gtk.main_quit()
        return True

    def timeout():
        out["error"] = "timed out"
        Gtk.main_quit()
        return False

    view.connect("load-changed", loaded)
    view.connect("load-failed", failed)
    view.load_uri(f"http://127.0.0.1:{PORT}{path}")
    timer = GLib.timeout_add_seconds(90, timeout)
    Gtk.main()
    if "error" not in out or out["error"] != "timed out":
        GLib.source_remove(timer)
    win.destroy()
    if "error" in out:
        check(f"the page ran ({path.split('?')[0]})", False, out["error"])
        return {}
    return out.get("value") or {}


print("== dialogs: Esc never says yes")
r = page(APP, """
await library();
// A dialog answered OK just before: "ok" must not carry over to the next one.
card('Delete me').querySelector('.more').click();
await sleep(100);
$('#askselect').value = 'delete';
$('#askok').click();
await until(() => $('#asktitle').textContent.includes('Delete “Delete me”'));
await key('Escape');
const notebook = { open: $('#askdlg').open, kept: titles().includes('Delete me') };
await openBook('Delete pages');
const count = () => $('#pagenum').textContent;
const pages = count();
$('#m-rename').click();
await sleep(100);
$('#askok').click();
await sleep(200);
$('#m-delpage').click();
await sleep(100);
await key('Escape');
const page = { before: pages, after: count() };
// Return on a yes/no question doesn't say yes either.
$('#m-delpage').click();
await sleep(100);
await key('Return');
const returned = count();
if ($('#askdlg').open) $('#askdlg').close('cancel');
// The export dialog, after a Save.
$('#exportdlg').returnValue = 'save';
$('#m-export').click();
await sleep(100);
await key('Escape');
await sleep(300);
const toast = $('#toast').hidden ? '' : $('#toast').textContent;
return { notebook, page, returned, toast };
""")
check("Esc on \"Delete notebook?\" keeps the notebook", r.get("notebook") == {"open": False, "kept": True}, r.get("notebook"))
check("Esc on \"Delete this page?\" keeps the page", r.get("page", {}).get("before") == r.get("page", {}).get("after") == "1 / 4", r.get("page"))
check("so does Return, on the question's Cancel", r.get("returned") == "1 / 4", r.get("returned"))
check("Esc on Save as PDF doesn't save", "PDF" not in r.get("toast", "x"), r.get("toast"))

print("== dialogs: Return says OK")
r = page(APP, """
await library();
const before = titles().length;
$('#l-new').click();
await sleep(100);
$('#askinput').value = 'Typed name';
$('#askinput').focus();
await key('Return');
const next = { open: $('#askdlg').open, title: $('#asktitle').textContent };
$('#askselect').value = 'letter';
[...$('#askdlg').querySelectorAll('button')].find((b) => b.value === 'cancel').click();
await sleep(200);
const cancelled = { open: $('#askdlg').open, added: titles().length - before };
$('#l-settings').click();
await sleep(100);
$('#pairbtn').click();
await sleep(200);
$('#manual').open = true;
$('#pairaddr').value = location.host;
$('#pairpin').value = '000000';
$('#pairpin').focus();
await key('Return');
await until(() => !$('#pairerr').hidden || !$('#certhelp').hidden || !$('#pairdlg').open);
const pair = { open: $('#pairdlg').open, error: $('#pairerr').textContent };
[...$('#pairdlg').querySelectorAll('button')].find((b) => b.value === 'cancel').click();
await sleep(100);
return { next, cancelled, pair, closed: !$('#pairdlg').open };
""")
check("Return in a name field goes on to the next step", r.get("next") == {"open": True, "title": "Page size"}, r.get("next"))
check("the Cancel button still cancels", r.get("cancelled") == {"open": False, "added": 0}, r.get("cancelled"))
check("Return in the PIN field tries to connect", r.get("pair", {}).get("open") is True and r.get("pair", {}).get("error"), r.get("pair"))
check("and the Close button closes", r.get("closed") is True)

print("== the toolbar fits")
MEASURE = """
await openBook('Toolbar');
await sleep(200);
const bar = $('#bar');
const menu = $('#menubtn').getBoundingClientRect();
return { over: bar.scrollWidth - bar.clientWidth, menuRight: Math.round(menu.right), vw: innerWidth, live: !$('#livebadge').hidden,
         pager: $('#pageno').textContent, colorsInline: !!$('#bar #colors'), toolsInline: !!$('#bar #tools') };
"""
for w, h, what in ((1366, 1024, "iPad Pro 12.9\" landscape"), (1194, 834, "iPad Pro 11\" landscape"), (1180, 820, "iPad Air landscape"), (1133, 744, "iPad mini landscape"),
                   (1024, 768, "iPad landscape"), (834, 1194, "iPad Pro 11\" portrait"), (768, 1024, "iPad portrait"), (744, 1133, "iPad mini portrait"),
                   (507, 820, "half a screen"), (375, 812, "a phone")):
    r = page(APP, MEASURE, (w, h))
    check(f"all of it fits at {w} ({what})", r.get("over") == 0 and r.get("menuRight", 9999) <= w and r.get("live"), r)
    if w >= 1180:
        check(f"with colors and widths in the toolbar at {w}", r.get("colorsInline"), r)
    if w >= 744:
        check(f"and the drawing tools at {w}", r.get("toolsInline"), r)
r = page(APP, MEASURE, (320, 568))
check("the ⋯ menu stays on screen even at 320", r.get("menuRight", 9999) <= 320, r)
r = page(APP, """
await openBook('Toolbar');
$('#livecount').textContent = 'Live · 12 guests, and then quite a few more';
await sleep(300);
const m = $('#menubtn').getBoundingClientRect();
const wide = { over: $('#bar').scrollWidth - $('#bar').clientWidth, right: Math.round(m.right), colorsInline: !!$('#bar #colors') };
$('#livecount').textContent = 'Live';
await sleep(300);
return { wide, back: !!$('#bar #colors'), hasDivider: !!$('#stylegroup').offsetWidth };
""", (1250, 820))
check("it refits when the Live badge grows", r.get("wide", {}).get("over") == 0 and r.get("wide", {}).get("right", 9999) <= 1250 and r.get("wide", {}).get("colorsInline") is False, r)
check("and when it shrinks", r.get("back") is True, r)
check("no empty group is left in the toolbar", r.get("hasDivider") is False, r)
r = page(APP, """
await openBook('Toolbar');
$('#stylebtn').click();
await sleep(100);
return { dots: [...document.querySelectorAll('#stylepop [data-w] i')].map((i) => i.getBoundingClientRect().width), pager: $('#pagenum').textContent };
""", (1024, 768))
check("the three pen widths look different in the pop-over", r.get("dots") == [4, 7, 11], r.get("dots"))
r = page(APP, """
await openBook('Long names');
await sleep(200);
const n = $('#pagenum').getBoundingClientRect();
const p = $('#pageno').getBoundingClientRect();
return { num: $('#pagenum').textContent, inside: n.right <= p.right + 1 && n.left >= p.left - 1 };
""", (768, 1024))
check("a section name can't push out the page number", r.get("inside") is True and r.get("num") == "1/3", r)

for w, h in ((1024, 768), (660, 900), (375, 812)):
    r = page(f"/join#w={srv.guests.tokens['w']}", """
await until(() => $('#pageno').textContent !== '–');
await sleep(300);
const save = $('#savebtn').getBoundingClientRect();
return { over: $('#bar').scrollWidth - $('#bar').clientWidth, right: Math.round(save.right) };
""", (w, h))
    check(f"the guest page's toolbar fits at {w}", r.get("over") == 0 and r.get("right", 9999) <= w, r)

print("== the share window: typing isn't a shortcut")
r = page(f"/view#c={srv.new_launch_code()}", """
await until(() => $('#b-sync').onclick);
$('#b-sync').click();
await until(() => $('#syncfolder').value);
const input = $('#syncfolder');
input.value = '';
input.focus();
for (const k of ['s', 'l', 'y', 'q', 'i', 'f', 'o', 'w']) await key(k);
const typed = { value: input.value, open: !$('#syncpanel').hidden, pair: !$('#pair').hidden, guests: !$('#guests').hidden, toast: $('#toast').hidden ? '' : $('#toast').textContent };
await key('Escape');
const escaped = $('#syncpanel').hidden;
input.blur();
await key('y');
return { typed, escaped, shortcut: !$('#syncpanel').hidden };
""")
check("letters go into the Sync folder field", r.get("typed", {}).get("value") == "slyqifow", r.get("typed"))
check("and do nothing else", r.get("typed", {}).get("open") is True and not r["typed"]["pair"] and not r["typed"]["guests"] and not r["typed"]["toast"], r.get("typed"))
check("Esc in the field still closes the panel", r.get("escaped") is True)
check("shortcuts still work outside it", r.get("shortcut") is True)

print("== opening a notebook isn't editing it")
r = page(APP, """
const store = await import('/store.js');
const record = async (title) => {
  const n = (await store.listNotebooks()).find((x) => x.title === title);
  return { modified: n.modified, dirty: !!n.dirty };
};
await library();
const order = titles();
const before = await record('Only opened');
await openBook('Only opened');
await sleep(800);
document.dispatchEvent(new Event('visibilitychange'));
await sleep(300);
$('#back').click();
await until(() => !$('#library').hidden);
await sleep(1000);
const after = await record('Only opened');
const editedBefore = await record('Really edited');
await openBook('Really edited');
$('#m-clear').click();
await sleep(800);
$('#back').click();
await until(() => !$('#library').hidden);
await sleep(1200);
return { order, orderAfter: titles().filter((t) => t !== 'Really edited'), before, after, editedBefore, editedAfter: await record('Really edited'), top: titles()[0], now: Date.now() };
""")
check("its date doesn't change", r.get("before", {}).get("modified") == r.get("after", {}).get("modified") and r.get("before"), r)
check("it doesn't need syncing", r.get("after", {}).get("dirty") is False, r.get("after"))
check("it stays where it was in the library", r.get("orderAfter") == [t for t in r.get("order", []) if t != "Really edited"], r)
check("a real edit does change its date", r.get("editedAfter", {}).get("modified", 0) > r.get("editedBefore", {}).get("modified", 0)
      and r.get("now", 0) - r.get("editedAfter", {}).get("modified", 0) < 60000, r)
check("and moves it to the top", r.get("top") == "Really edited", r.get("top"))
time.sleep(0.5)
edited = next(srv.store.get(i) for i in srv.store.ids() if srv.store.get(i)["title"] == "Really edited")
check("and reaches the computer", not edited["pages"][N.order(edited)[0]]["strokes"])

srv.shutdown()
srv.server_close()
print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
