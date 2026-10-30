#!/usr/bin/env python3
"""CI helper: join the live session as a guest and draw one stroke.

    python3 ios/ci/guest_stroke.py <port> <guest token> <stroke id>

Prints the page it drew on. Standard library only.
"""

import base64
import json
import os
import socket
import struct
import sys

port, token, sid = int(sys.argv[1]), sys.argv[2], sys.argv[3]
s = socket.create_connection(("127.0.0.1", port), timeout=10)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall(f"GET /ws?g={token}&v=5&me=ciguest HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\n"
          f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode())
head = b""
while b"\r\n\r\n" not in head:
    head += s.recv(1)
assert b" 101 " in head.split(b"\r\n")[0], head


def read(n):
    out = b""
    while len(out) < n:
        chunk = s.recv(n - len(out))
        if not chunk:
            raise ConnectionError
        out += chunk
    return out


def recv():
    b1, b2 = read(2)
    n = b2 & 127
    if n == 126:
        n = struct.unpack("!H", read(2))[0]
    elif n == 127:
        n = struct.unpack("!Q", read(8))[0]
    data = read(n)
    return json.loads(data) if b1 & 15 == 1 else None


def send(obj):
    p = json.dumps(obj).encode()
    mask = os.urandom(4)
    n = len(p)
    h = bytes([0x81, 0x80 | n]) if n < 126 else bytes([0x81, 0x80 | 126]) + struct.pack("!H", n)
    s.sendall(h + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(p)))


while True:
    m = recv()
    if m and m.get("t") == "state":
        page = m["page"]
        break
pts = [[150 + i * 15, 980 + (i % 5) * 6, 0.5] for i in range(25)]
send({"t": "begin", "page": page, "s": {"id": sid, "z": 9e15, "tool": "pen", "color": "#d62f2f", "width": 6, "pts": pts[:1]}})
send({"t": "pts", "id": sid, "pts": pts[1:]})
send({"t": "end", "id": sid})
print(page)
s.close()
