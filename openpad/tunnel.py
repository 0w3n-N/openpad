"""Internet links for guests, through a Cloudflare quick tunnel.

Off unless the owner switches it on for a session. cloudflared connects out to
Cloudflare and gets a random https://<words>.trycloudflare.com address that
forwards to this server; no account or open port is needed. It forwards to a
port of its own on 127.0.0.1 (server.TunnelListener), open only while it runs,
where the server only answers guest requests (see Handler._tunnel_ok), so the
owner key is never usable from the internet.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import threading

URL_RE = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com")
NO_WINDOW = {"creationflags": 0x08000000} if os.name == "nt" else {}


def cloudflared():
    found = shutil.which("cloudflared")
    if found or os.name != "nt":
        return found
    for base in (os.environ.get("ProgramFiles(x86)"), os.environ.get("ProgramFiles")):
        exe = os.path.join(base or "", "cloudflared", "cloudflared.exe")
        if base and os.path.isfile(exe):
            return exe
    return None


class Tunnel:
    def __init__(self, listener, on_change):
        self.listener = listener  # the local port cloudflared forwards to (server.TunnelListener)
        self.on_change = on_change
        self.proc = None
        self.url = None
        self.state = "off"  # off | starting | on | error
        self.error = ""
        self.lock = threading.Lock()

    @property
    def host(self):
        return self.url[len("https://"):] if self.url else None

    def info(self):
        return {"state": self.state, "url": self.url, "error": self.error, "available": bool(cloudflared())}

    def start(self):
        exe = cloudflared()
        with self.lock:
            if self.proc:
                return
            if not exe:
                self.state, self.error = "error", "cloudflared is not installed. Run setup on the computer."
                self.on_change()
                return
            try:
                port = self.listener.open()
            except OSError as e:
                self.state, self.error = "error", f"Could not open a local port for the internet link: {e}"
                self.on_change()
                return
            self.state, self.error, self.url = "starting", "", None
            # --config to an empty file: a user's own ~/.cloudflared/config.yml
            # (named tunnels, ingress rules) must not apply to this one.
            try:
                self.proc = subprocess.Popen(
                    [exe, "tunnel", "--no-autoupdate", "--config", os.devnull,
                     "--url", f"http://127.0.0.1:{port}"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                    text=True, errors="replace", **NO_WINDOW)
            except OSError as e:
                self.listener.close()
                self.state, self.error = "error", f"Could not start cloudflared: {e}"
                self.on_change()
                return
            proc = self.proc
        self.on_change()
        threading.Thread(target=self._watch, args=(proc,), daemon=True).start()

    def _watch(self, proc):
        tail = []
        for line in proc.stderr:
            tail = (tail + [line.strip()])[-5:]
            m = URL_RE.search(line)
            if m and self.proc is proc and not self.url:
                with self.lock:
                    self.url, self.state = m.group(0), "on"
                self.on_change()
        proc.wait()
        with self.lock:
            if self.proc is not proc:
                return
            self.proc, self.url = None, None
            self.listener.close()
            if self.state != "off":
                self.state = "error"
                self.error = "The internet link stopped. " + (tail[-1][:200] if tail else "")
        self.on_change()

    def stop(self):
        with self.lock:
            proc, self.proc, self.url, self.state, self.error = self.proc, None, None, "off", ""
            self.listener.close()
        if proc:
            proc.terminate()
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                proc.kill()
        self.on_change()
