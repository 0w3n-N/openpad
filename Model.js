.pragma library

// Pure helpers for Panel.qml. Everything read from disk or from a process is
// treated as untrusted: parsed defensively, bounded, and reduced to plain values.

var STALE_AFTER_SEC = 25

function singleLine(value, limit) {
  return String(value === undefined || value === null ? "" : value).replace(/[\r\n\t]+/g, " ").slice(0, limit)
}

function toInt(value, lo, hi, fallback) {
  var n = Math.round(Number(value))
  return isFinite(n) ? Math.max(lo, Math.min(hi, n)) : fallback
}

// status.json written by the server (see openpad/server.py write_status).
function parseStatus(raw, nowSec) {
  var empty = { running: false, pads: 0, views: 0, guests: 0, notebook: "", internet: false, url: "", qr: [], qrSize: 0, page: 0, pages: 0, port: 0, live: "idle", syncFolder: "", lastSync: null }
  if (typeof raw !== "string" || raw.length === 0 || raw.length > 200000) return empty
  var s
  try { s = JSON.parse(raw) } catch (e) { return empty }
  if (!s || typeof s !== "object" || s.app !== "openpad") return empty
  var updated = Number(s.updated)
  var fresh = isFinite(updated) && Math.abs(nowSec - updated) < STALE_AFTER_SEC
  var qr = []
  if (Array.isArray(s.qr) && s.qr.length >= 21 && s.qr.length <= 200) {
    var size = s.qr.length
    for (var i = 0; i < size; i++) {
      var row = s.qr[i]
      if (typeof row !== "string" || row.length !== size || !/^[01]+$/.test(row)) { qr = []; break }
      qr.push(row)
    }
  }
  var url = singleLine(s.url, 300)
  if (!/^http:\/\/[A-Za-z0-9.\-\[\]:]+\/(app)?\?k=[A-Za-z0-9_-]+$/.test(url)) url = ""
  return {
    running: s.running === true && fresh,
    pads: toInt(s.pads, 0, 99, 0),
    views: toInt(s.views, 0, 99, 0),
    guests: toInt(s.guests, 0, 99, 0),
    syncFolder: singleLine(s.syncFolder, 300),
    lastSync: s.lastSync && typeof s.lastSync === "object" ? {
      time: toInt(s.lastSync.time, 0, 9999999999, 0),
      ok: s.lastSync.ok === true,
      notebooks: toInt(s.lastSync.notebooks, 0, 100000, 0),
      error: singleLine(s.lastSync.error, 200)
    } : null,
    notebook: singleLine(s.notebook, 80),
    internet: typeof s.internet === "string" && /^https:\/\/[a-z0-9-]+\.trycloudflare\.com$/.test(s.internet),
    url: url,
    qr: qr,
    qrSize: qr.length,
    page: toInt(s.page, 0, 100000, 0),
    pages: toInt(s.pages, 0, 100000, 0),
    port: toInt(s.port, 0, 65535, 0),
    live: s.running === true && fresh && (s.live === "picking" || s.live === "live") ? s.live : "idle"
  }
}

// `openpad doctor --json`.
function parseDoctor(raw) {
  var d = { known: false, uxplay: false, cloudflared: false, avahi: false, capture: false, firewall: "unknown", lan: "" }
  if (typeof raw !== "string" || raw.length > 10000) return d
  try {
    var j = JSON.parse(raw)
    d.known = true
    d.uxplay = j.uxplay === true
    d.cloudflared = j.cloudflared === true
    d.avahi = j.avahi === true
    d.capture = j.capture === true
    d.firewall = ["open", "configured", "needs-setup"].indexOf(j.firewall) >= 0 ? j.firewall : "unknown"
    d.lan = singleLine(j.lan, 64)
  } catch (e) {}
  return d
}

function needsSetup(d) {
  return d.known && (!d.capture || d.firewall === "needs-setup")
}

function statusLine(st, mirroring) {
  if (!st.running) return mirroring ? "Mirroring on" : "Off"
  var guests = st.guests > 0 ? (st.guests === 1 ? " · 1 guest" : " · " + st.guests + " guests") : ""
  if (st.pads > 0) return (st.pads === 1 ? "iPad connected" : st.pads + " iPads connected") + guests
  return "Waiting for iPad" + guests
}

function detailLine(st) {
  if (!st.running) return ""
  var parts = st.notebook ? [st.notebook] : []
  parts.push(st.pages === 1 ? "1 page" : st.pages + " pages")
  parts.push(st.views === 1 ? "1 window open" : st.views + " windows open")
  return parts.join(" · ")
}

// "Synced 5 min ago · ~/Documents/OpenPad"
function syncLine(st, nowSec) {
  var folder = String(st.syncFolder || "").replace(/^\/home\/[^/]+/, "~")
  var last = st.lastSync
  if (!last || !last.time) return folder ? "Copies everything to " + folder : "Copy every notebook to this computer"
  if (!last.ok) return "Last sync failed: " + last.error
  var mins = Math.max(0, Math.round((nowSec - last.time) / 60))
  var ago = mins < 1 ? "just now" : mins < 60 ? mins + " min ago" : mins < 1440 ? Math.round(mins / 60) + " h ago" : Math.round(mins / 1440) + " d ago"
  return "Synced " + ago + (folder ? " · " + folder : "")
}

// Quote one argument for the floating-terminal launcher, which runs `bash -c`.
function shellQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'"
}

function parseMirror(raw) {
  try {
    var j = JSON.parse(String(raw || ""))
    return { name: singleLine(j.name, 40), pin: /^\d{4}$/.test(j.pin) ? j.pin : "" }
  } catch (e) {
    return { name: "", pin: "" }
  }
}

function airplayName(value) {
  var name = singleLine(value, 40).replace(/[^\w .'-]/g, "").trim()
  return name.length > 0 ? name : "Omarchy"
}

function urlForDisplay(url) {
  // Show the address without the key; the key is in the QR code.
  return String(url || "").replace(/\?k=.*$/, "")
}
