# Security

OpenPad runs a web server on your computer so the iPad (and guests you invite)
can reach it over the local network. This file covers what that exposes and
what the plugin does on your system.

## What runs, and with which privileges

- Nothing starts automatically. The server runs only while you have it
  switched on.
- The bar widget runs `bin/openpad` with argument lists, never a shell string,
  and reads status files in `$XDG_RUNTIME_DIR/openpad/`. It never uses sudo.
- `scripts/setup` (Linux, macOS; run by you, in a terminal) asks before each
  step. It uses sudo only for `pacman`/`yay` package installs, `ufw allow`
  rules limited to private network ranges and tagged `openpad` (and deleting
  old rules tagged `inkcast`), and `systemctl enable --now avahi-daemon`.
  `scripts/uninstall` removes the rules and the optional command and launcher
  entries.
- `scripts\setup.ps1` (Windows) asks before each step. It requests admin rights
  through the normal Windows prompt only to add one firewall rule (inbound
  TCP 8770, Private networks only, group `OpenPad`) and, if you agree, to mark
  your network as Private. Python and cloudflared come from winget.
  `scripts\uninstall.ps1` removes the rule, the shortcut and the PATH entry.
- No code is downloaded at runtime. There are no pip packages or bundled
  binaries. `web/vendor/pdfjs` is Mozilla's pdf.js 4.10.38, copied unmodified
  from npm (its hash is in `web/vendor/pdfjs/README.md`). It runs in the
  browser with `isEvalSupported: false`.
- Data (notebooks, PDFs and images they show, pairing key, guest links, the
  certificate authority) is stored in `~/.local/share/openpad/` (Linux) or
  `~/Library/Application Support/openpad/` (macOS), with directories at mode
  700 and files at 600. On Windows it's in `%LOCALAPPDATA%\OpenPad\`, which only
  your account can read. The readable PDFs in `Documents/OpenPad` are also 700
  and 600.

## The server (TCP 8770)

- **Owner key.** The notes app, the share window and the CLI need a 128-bit
  key from `~/.local/share/openpad/token`, which is carried in the pairing QR
  code. There's no exception for localhost, so other local users and websites
  open in your browser are refused. Delete the file and restart to issue a new
  key; this unpairs every device.
- **Guests** get separate 128-bit tokens, one for "can draw" links and one for
  "view only". With either, a guest can only receive the notebook currently
  shown and the PDFs and images on its pages. A "can draw" guest can add ink
  and remove only ink tagged with their own id. Guests can't read other
  notebooks, sync, turn pages for others, rename or restructure anything, add
  files, start window capture, or reach any owner endpoint. Guest tokens
  are new every time OpenPad starts, and **New links** replaces them sooner
  and disconnects every guest. At most 20 guests can connect.
- **Nothing shown by default.** When no notebook is open on the iPad (at
  start, or after the one on screen is deleted), the share window and guests
  get an empty, read-only placeholder, never another notebook.
- **Browser attacks.** Requests whose `Host` isn't this computer are refused,
  which blocks DNS rebinding. Requests that carry an `Origin` must come from
  OpenPad's own pages. The one exception is the installed app's origin,
  `https://0w3n-n.github.io`, which may make requests with the owner key
  (CORS) but is refused with guest tokens.
- **Connecting the installed app.** It reads the key from the QR code the
  computer shows (the same code as the Safari link), or trades the 6-digit
  PIN shown under it for the key. A PIN exists only once the computer's screen
  shows one, expires after 10 minutes or 5 wrong tries, works once, and the
  server accepts one try per second. After 20 wrong PINs in a day, PIN pairing
  stops (the QR code still works) until the day is up or OpenPad restarts.
- **Opening the share window** uses a one-time code that expires after 60 s,
  so the key never appears on a process command line.
- **Input** from devices is validated and rebuilt before it's stored, merged or
  relayed. This covers IDs, colors, finite and clamped numbers, allowlisted
  tools and paper types, and backgrounds, which may only name files by their
  SHA-256. Uploaded files must match the hash they're stored under. Readable
  PDFs must start with `%PDF-`, and their file names are reduced to safe
  characters inside the notes folder.
- **Limits:** 200 MB per file, 64 MB per synced notebook, 2 MB per owner
  message and 512 KB per guest message, caps on pages, strokes, points and
  connections, and socket timeouts.
- **Port:** on Windows the server binds its port exclusively
  (`SO_EXCLUSIVEADDRUSE`), so another program can't bind the same port
  alongside it.
- **Pages** are served with a strict Content-Security-Policy, `nosniff`,
  `no-referrer` and no framing. Static files come from a fixed allowlist.

## Encryption

- **HTTP (Safari from the QR code, guests on your Wi-Fi):** plain HTTP. On your
  own WPA2/WPA3 Wi-Fi the radio link is encrypted. On open or shared networks,
  others on that network could read the traffic, including the key, so don't
  use it there.
- **HTTPS (the installed app):** the same port also speaks TLS 1.2+. OpenPad
  creates its own certificate authority (P-256, in `tls/` in the data folder)
  and a server certificate for your LAN addresses and `<hostname>.local`,
  re-issued when the address changes. You install the authority's certificate
  on the iPad yourself, from the setup page. Check its SHA-256 fingerprint on
  that page against the one iOS shows.
- **The authority is name-constrained** to private IPv4 ranges, CGNAT,
  loopback, IPv6 ULAs, `.local` and `localhost`. Even with its key, nobody can
  make a certificate the iPad would accept for a real website. The key never
  leaves your computer. To revoke it, delete the certificate profile on the
  iPad (Settings › General › VPN & Device Management) and delete `tls/` on the
  computer.

## The sync folder

The copy of your notebooks is written only by the server, with the owner key
required to choose its location (`/api/settings`), and only to a folder of its
own: not `/`, your home folder itself, or OpenPad's data folder. Folder and
notebook names are reduced to safe path segments (no separators, no leading
dots), so names can't point outside it. Folders OpenPad creates are mode 700
and files 600. Changing the folder leaves the old copy in place; nothing is
deleted there except files OpenPad wrote itself (a renamed section's old PDF, a
deleted notebook's folder, which moves to OpenPad's trash).

The computer's **Sync** button only asks connected notes apps to sync; it can't
read anything from the iPad by itself. Only the notes app (owner key, `pad`
role) can report a sync as done.

## Internet links (optional)

Off unless you switch them on. OpenPad then runs `cloudflared tunnel --url
http://127.0.0.1:8770` with an empty config file, which gives a random
`https://<words>.trycloudflare.com` address. Through that address the server
only answers guest pages, guest WebSockets and the live notebook's files.
The owner key is refused there, owner pages and APIs answer 404, and no key
proof is given. Cloudflare terminates TLS, so Cloudflare can see that traffic.
The tunnel stops when you switch it off or stop OpenPad.

## Other users on the same computer

- Secrets are never passed as program arguments, which any user can read in
  `/proc/<pid>/cmdline`. QR codes are generated inside OpenPad (`openpad/qr.py`),
  without running another program. The browser is given only the path of an
  owner-only page, which passes a one-time code in the URL fragment. UxPlay
  reads its PIN from an owner-only options file.
- Before the CLI or the bar widget sends the key to the server, the server
  must prove it holds the key (an HMAC of a fresh random challenge). If another
  program is listening on the port, the CLI refuses and says so.
- Limit: when OpenPad is off, another user could listen on its port and
  receive the key from an iPad that opens a saved link. On a shared computer,
  only use the iPad link while OpenPad is running, or change the port.

## Desktop annotation

- On Linux, window capture goes through the standard screen-share portal. On
  macOS and Windows, the share window captures it with the browser's own
  screen-share dialog. Either way, a window is only captured after someone at
  the computer picks it. A paired iPad can ask for the picker but can't choose
  a window itself, and guests can't ask at all.
- Frames go to everyone viewing the live notebook, guests included, so only
  annotate windows you'd show on the call. Capture stops when you stop it,
  when you delete its page, or when the window closes. The last frame is
  stored as an owner-only file.

## AirPlay mirroring

UxPlay starts with a random 4-digit PIN, and devices that entered it are
remembered in `~/.local/share/openpad/airplay-devices`. UxPlay only listens
while mirroring is on. `--no-pin` turns the PIN off.

## Reporting a problem

For a security problem, open an issue asking for a private contact. Don't
post the details publicly. Use issues as normal for everything else.
