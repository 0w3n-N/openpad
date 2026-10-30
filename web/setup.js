// Setup page for the installed app, opened from the computer's Pair screen.

const $ = (s) => document.querySelector(s);
const key = new URLSearchParams(location.search).get('k') || '';
const K = `k=${encodeURIComponent(key)}`;

async function refresh() {
  try {
    const r = await fetch(`/api/pairing?${K}`);
    if (!r.ok) throw new Error();
    const p = await r.json();
    $('#addr').textContent = p.addresses[0] || location.host;
    $('#pin').textContent = p.pin || '— (too many wrong tries today: use the QR code)';
    $('#fp').textContent = p.fingerprint;
    $('#openapp').href = p.app;
    setTimeout(refresh, Math.max(5, Math.min(60, p.expires)) * 1000);
  } catch {
    $('#pin').textContent = '—';
    setTimeout(refresh, 5000);
  }
}

$('#getca').href = `/api/ca.crt?${K}`;
refresh();
