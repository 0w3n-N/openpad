"""Internet links for guests, through a Cloudflare quick tunnel.

Off unless the owner switches it on for a session. cloudflared connects out to
Cloudflare and gets a random https://<words>.trycloudflare.com address that
forwards to this server; no account or open port is needed. The server only
answers guest requests on that address (see Handler._tunnel_ok), so the owner
key is never usable from the internet.
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
    def __init__(self, port, on_change):
        self.port = port
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
            self.state, self.error, self.url = "starting", "", None
            # --config to an empty file: a user's own ~/.cloudflared/config.yml
            # (named tunnels, ingress rules) must not apply to this one.
            self.proc = subprocess.Popen(
                [exe, "tunnel", "--no-autoupdate", "--config", os.devnull,
                 "--url", f"http://127.0.0.1:{self.port}"],
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                text=True, errors="replace", **NO_WINDOW)
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
            if self.state != "off":
                self.state = "error"
                self.error = "The internet link stopped. " + (tail[-1][:200] if tail else "")
        self.on_change()

    def stop(self):
        with self.lock:
            proc, self.proc, self.url, self.state, self.error = self.proc, None, None, "off", ""
        if proc:
            proc.terminate()
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                proc.kill()
        self.on_change()
