"""HTTPS for the installed iPad app.

The offline app is served from GitHub Pages over HTTPS, and a secure page may
only talk to HTTPS servers. So OpenPad makes its own small certificate
authority, the user installs it on the iPad once, and the server presents a
certificate for its LAN addresses signed by it.

The CA is name-constrained: it can only vouch for private IP ranges and
*.local names, so even someone who stole its key couldn't impersonate a real
website to the iPad. Its key stays in the owner-only data folder.

Standard library only: P-256 ECDSA and the few DER structures X.509 needs are
written out below (they're small), so there's nothing to install.
"""

from __future__ import annotations

import base64
import datetime
import hashlib
import ipaddress
import os
import secrets
import socket
import ssl
import threading
from pathlib import Path

# --------------------------------------------------------------------------- P-256

P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
A = P - 3
B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
G = (0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
     0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5)


def _add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    (x1, y1), (x2, y2) = p1, p2
    if x1 == x2 and (y1 + y2) % P == 0:
        return None
    if p1 == p2:
        lam = (3 * x1 * x1 + A) * pow(2 * y1, -1, P) % P
    else:
        lam = (y2 - y1) * pow(x2 - x1, -1, P) % P
    x3 = (lam * lam - x1 - x2) % P
    return x3, (lam * (x1 - x3) - y1) % P


def _mul(k, pt=G):
    out = None
    while k:
        if k & 1:
            out = _add(out, pt)
        pt = _add(pt, pt)
        k >>= 1
    return out


def new_key():
    d = secrets.randbelow(N - 1) + 1
    return d, _mul(d)


def sign(d, message: bytes) -> bytes:
    e = int.from_bytes(hashlib.sha256(message).digest(), "big")
    while True:
        k = secrets.randbelow(N - 1) + 1
        r = _mul(k)[0] % N
        s = pow(k, -1, N) * (e + r * d) % N
        if r and s:
            return seq(integer(r), integer(s))


def point_bytes(q):
    return b"\x04" + q[0].to_bytes(32, "big") + q[1].to_bytes(32, "big")


# --------------------------------------------------------------------------- DER


def tlv(tag: int, body: bytes) -> bytes:
    n = len(body)
    if n < 0x80:
        size = bytes([n])
    else:
        raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
        size = bytes([0x80 | len(raw)]) + raw
    return bytes([tag]) + size + body


def seq(*parts):
    return tlv(0x30, b"".join(parts))


def integer(v: int):
    raw = v.to_bytes(max(1, (v.bit_length() + 8) // 8), "big")  # leading 0 keeps it positive
    return tlv(0x02, raw)


def oid(dotted: str):
    nums = [int(x) for x in dotted.split(".")]
    body = bytes([nums[0] * 40 + nums[1]])
    for n in nums[2:]:
        chunk = [n & 0x7F]
        n >>= 7
        while n:
            chunk.append(0x80 | (n & 0x7F))
            n >>= 7
        body += bytes(reversed(chunk))
    return tlv(0x06, body)


def bitstring(data: bytes, unused=0):
    return tlv(0x03, bytes([unused]) + data)


def octets(data: bytes):
    return tlv(0x04, data)


def utf8(text: str):
    return tlv(0x0C, text.encode())


def when(t: datetime.datetime):
    if t.year < 2050:
        return tlv(0x17, t.strftime("%y%m%d%H%M%SZ").encode())
    return tlv(0x18, t.strftime("%Y%m%d%H%M%SZ").encode())


def name(cn: str):
    return seq(tlv(0x31, seq(oid("2.5.4.10"), utf8("OpenPad"))),
               tlv(0x31, seq(oid("2.5.4.3"), utf8(cn))))


def extension(ext_oid, value: bytes, critical=False):
    return seq(oid(ext_oid), *( [tlv(0x01, b"\xff")] if critical else [] ), octets(value))


ECDSA_SHA256 = seq(oid("1.2.840.10045.4.3.2"))
EC_PUBLIC_KEY = seq(oid("1.2.840.10045.2.1"), oid("1.2.840.10045.3.1.7"))

# What the CA may vouch for: private addresses and *.local names only.
PERMITTED = [ipaddress.ip_network(n) for n in
             ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "127.0.0.0/8", "fc00::/7", "::1/128")]
PERMITTED_DNS = ("local", "localhost")


def _general_names(names):
    out = b""
    for n in names:
        try:
            out += tlv(0x87, ipaddress.ip_address(n).packed)
        except ValueError:
            out += tlv(0x82, n.encode())
    return out


def _name_constraints():
    subtrees = b""
    for net in PERMITTED:
        subtrees += seq(tlv(0x87, net.network_address.packed + net.netmask.packed))
    for d in PERMITTED_DNS:
        subtrees += seq(tlv(0x82, d.encode()))
    return seq(tlv(0xA0, subtrees))


def certificate(subject_cn, subject_key, issuer_cn, issuer_d, issuer_q, days, ca=False, names=()):
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    ski = hashlib.sha1(point_bytes(subject_key)).digest()
    aki = hashlib.sha1(point_bytes(issuer_q)).digest()
    exts = [extension("2.5.29.14", octets(ski))]
    if ca:
        exts += [extension("2.5.29.19", seq(tlv(0x01, b"\xff"), integer(0)), critical=True),
                 extension("2.5.29.15", bitstring(b"\x06", 1), critical=True),  # keyCertSign, cRLSign
                 extension("2.5.29.30", _name_constraints(), critical=True)]
    else:
        exts += [extension("2.5.29.35", seq(tlv(0x80, aki))),
                 extension("2.5.29.19", seq(), critical=True),
                 extension("2.5.29.15", bitstring(b"\x80", 7), critical=True),  # digitalSignature
                 extension("2.5.29.37", seq(oid("1.3.6.1.5.5.7.3.1"))),       # serverAuth
                 extension("2.5.29.17", seq(_general_names(names)))]
    tbs = seq(
        tlv(0xA0, integer(2)),
        integer(int.from_bytes(secrets.token_bytes(16), "big") >> 1 | 1),
        ECDSA_SHA256,
        name(issuer_cn),
        seq(when(now - datetime.timedelta(hours=1)), when(now + datetime.timedelta(days=days))),
        name(subject_cn),
        seq(EC_PUBLIC_KEY, bitstring(point_bytes(subject_key))),
        tlv(0xA3, seq(*exts)),
    )
    return seq(tbs, ECDSA_SHA256, bitstring(sign(issuer_d, tbs)))


def private_key_pem(d, q):
    der = seq(integer(1), octets(d.to_bytes(32, "big")),
              tlv(0xA0, oid("1.2.840.10045.3.1.7")), tlv(0xA1, bitstring(point_bytes(q))))
    return pem("EC PRIVATE KEY", der)


def pem(label, der):
    b64 = base64.encodebytes(der).decode().replace("\n", "")
    lines = "\n".join(b64[i:i + 64] for i in range(0, len(b64), 64))
    return f"-----BEGIN {label}-----\n{lines}\n-----END {label}-----\n"


def read_pem(text, label):
    start, end = f"-----BEGIN {label}-----", f"-----END {label}-----"
    body = text.split(start, 1)[1].split(end, 1)[0]
    return base64.b64decode("".join(body.split()))


def parse_private_key(text):
    """d and Q back from private_key_pem() (only our own layout)."""
    der = read_pem(text, "EC PRIVATE KEY")
    i = der.index(b"\x04\x20") + 2
    d = int.from_bytes(der[i:i + 32], "big")
    return d, _mul(d)


# --------------------------------------------------------------------------- files


class LocalCA:
    """The CA and the current server certificate, in <data dir>/tls."""

    SERVER_DAYS = 397  # Apple rejects server certificates valid for longer

    def __init__(self, folder: Path, write_private):
        self.dir = folder
        self.write = write_private
        self.lock = threading.Lock()
        self.context = None
        self.names: tuple[str, ...] = ()
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        if os.name != "nt":
            os.chmod(folder, 0o700)
        self._load_ca()

    def _load_ca(self):
        key_f, crt_f = self.dir / "ca-key.pem", self.dir / "ca.pem"
        try:
            self.ca_d, self.ca_q = parse_private_key(key_f.read_text())
            self.ca_der = read_pem(crt_f.read_text(), "CERTIFICATE")
            return
        except (OSError, ValueError, IndexError):
            pass
        self.ca_d, self.ca_q = new_key()
        host = socket.gethostname().split(".")[0][:40] or "computer"
        self.ca_der = certificate(f"OpenPad on {host}", self.ca_q, f"OpenPad on {host}",
                                  self.ca_d, self.ca_q, 3650, ca=True)
        self.write(key_f, private_key_pem(self.ca_d, self.ca_q))
        self.write(crt_f, pem("CERTIFICATE", self.ca_der))
        for f in self.dir.glob("server*"):
            f.unlink(missing_ok=True)

    @property
    def issuer_cn(self):
        return self._cn(self.ca_der)

    @staticmethod
    def _cn(der):
        i = der.rfind(bytes.fromhex("0603550403"))  # the subject's commonName
        n = der[i + 6]
        return der[i + 7:i + 7 + n].decode(errors="replace")

    def fingerprint(self):
        h = hashlib.sha256(self.ca_der).hexdigest().upper()
        return " ".join(h[i:i + 2] for i in range(0, len(h), 2))

    def ensure(self, names):
        """An SSL context whose certificate covers `names` (LAN addresses and
        the .local hostname). Re-issued when the address changes."""
        names = tuple(sorted({n for n in names if permitted(n)}))
        with self.lock:
            if self.context and names == self.names:
                return self.context
            key_f, crt_f, names_f = self.dir / "server-key.pem", self.dir / "server.pem", self.dir / "server-names"
            try:
                ok = names_f.read_text() == ",".join(names) and \
                    (datetime.datetime.now().timestamp() - crt_f.stat().st_mtime) < (self.SERVER_DAYS - 30) * 86400
            except OSError:
                ok = False
            if not ok:
                d, q = new_key()
                der = certificate("OpenPad server", q, self.issuer_cn, self.ca_d, self.ca_q, self.SERVER_DAYS, names=names)
                self.write(key_f, private_key_pem(d, q))
                self.write(crt_f, pem("CERTIFICATE", der) + pem("CERTIFICATE", self.ca_der))
                self.write(names_f, ",".join(names))
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.minimum_version = ssl.TLSVersion.TLSv1_2
            ctx.load_cert_chain(crt_f, key_f)
            self.context, self.names = ctx, names
            return ctx


def permitted(n):
    try:
        a = ipaddress.ip_address(n)
        return any(a in net for net in PERMITTED)
    except ValueError:
        return n == "localhost" or (n.endswith(".local") and len(n) > 6)


# --------------------------------------------------------------------------- serving


def pump(tls_sock, plain_sock, timeout):
    """Copy bytes both ways between a TLS client and the plain HTTP handler.

    One thread owns the TLS socket for reading and writing, because an SSL
    connection isn't safe to use from two threads at once."""
    import selectors

    sel = selectors.DefaultSelector()
    sel.register(tls_sock, selectors.EVENT_READ)
    sel.register(plain_sock, selectors.EVENT_READ)
    try:
        while True:
            ready = [k.fileobj for k, _ in sel.select(timeout)] if not tls_sock.pending() else [tls_sock]
            if not ready:
                return  # idle past the timeout
            for s in ready:
                if s is tls_sock:
                    data = tls_sock.recv(65536)
                    if not data:
                        return
                    plain_sock.sendall(data)
                else:
                    data = plain_sock.recv(65536)
                    if not data:
                        return
                    tls_sock.sendall(data)
    except (OSError, ssl.SSLError):
        return
    finally:
        sel.close()
        for s in (tls_sock, plain_sock):
            try:
                s.close()
            except OSError:
                pass
