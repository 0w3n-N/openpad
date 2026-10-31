# Changelog

Each version is released on GitHub with the iPad app (`OpenPad.ipa`, for
SideStore). The computer side updates with `omarchy plugin update`. For
versions before 0.6.0 (Inkcast, OpenPad 0.5), see the git history.

## 0.7.5 (2026-10-31)

- **Privacy: "Show on the computer" off now really hides the notebook.** It
  used to only stop live drawing. The notebook stayed on the computer's
  screen, so edits that synced in the background still reached the share
  window and guests. Now turning it off (on the iPad app or the web app)
  takes the notebook off the screen, and it stays off while you write until
  you turn it back on. Found in the Omarchy plugin marketplace review.

## 0.7.4 (2026-10-31)

- **Fixed: big notebooks could keep your share window or iPad reconnecting.**
  0.7.3 treated a client that was still downloading a notebook over 16 MiB
  as stuck, and disconnected it whenever anything else was sent meanwhile.
  Now only small backed-up messages count, and a newer copy of the notebook
  replaces older unsent ones.
- **Security: guests can't make the computer hold large amounts of memory.**
  - Files a guest asks for in parts (PDF pages) are sent in 1 MiB pieces
    instead of being read whole into memory. This was found in the Omarchy
    plugin marketplace review.
  - The notebook on screen is encoded once per page and shared by everyone
    watching, instead of copied for each viewer.
  - Guests together can add up to 10,000 strokes and 250,000 points per
    session, far more than a call needs; **New links** starts a new session.
    A guest page says so when the limit is reached.
- Erasing no longer re-sorts the page's whole list of erased strokes each time.

## 0.7.3 (2026-10-31)

- **Security: a guest can't exhaust the computer's memory.** Anyone with a
  guest link, even view-only, could send endless empty message fragments,
  flood pings without reading the replies, or stop reading while the
  notebook changed, and the server kept everything. Now fragments count
  toward the message limit, ping replies don't pile up, and a client more
  than 16 MiB behind is disconnected (it reconnects and gets the current
  state). The fragment problem was found in the Omarchy plugin marketplace
  review; the other two turned up while fixing it.

## 0.7.2 (2026-10-31)

- **Security: guests can't pose as each other.** A guest with a "can draw"
  link could reconnect using another guest's id (shown on that guest's
  strokes) and erase their ink. A guest's id is now a keyed hash of a private
  secret their browser keeps, so a visible id can't be reused. Guests keep
  their id across reconnects, as before; ids from before this update change
  once. Found in the Omarchy plugin marketplace review.

## 0.7.1 (2026-10-30)

- **PIN pairing is harder to guess.** A PIN is dropped after 5 wrong tries,
  and a new one appears only when the computer's screen asks for it, instead
  of right away. After 20 wrong PINs in a day, only the QR code pairs. Before,
  someone on the same Wi-Fi could keep guessing for as long as the share
  window was open.
- Guests can no longer end a stroke someone else is drawing.
- The computer no longer relays the old iPad stroke previews (unused since
  0.7.0).
- The Sync button works with a sync folder whose name starts with "-".
- Folder and file names in the sync folder never end in a dot or space, and
  avoid Windows' reserved names like `COM1.notes`.
- `scripts/uninstall` finds OpenPad's data on macOS.

## 0.7.0 (2026-10-30)

- **The iPad app has OpenPad's own ink and the web app's tools** instead of
  Apple's: pen, highlighter, eraser, select and move, and shapes (line,
  arrow, box, ellipse, axes), with seven colors, three widths, undo and redo.
  Hold the Pencil still at the end of a stroke to straighten it.
- **Pressure sensitivity** in Settings, with a preview, sets how much
  pressing harder thickens the line.
- Ink looks the same on the iPad, on the computer and in PDFs, and stays
  sharp at any zoom.
- Strokes show on the computer while you write them, and guests' strokes
  show on the iPad while they write them.
- The Pencil's double-tap and squeeze switch to the eraser and back (or as
  set in Settings › Apple Pencil).

## 0.6.1 (2026-10-29)

- Fixed: on the iPad, parts of a page could show as black squares, or with
  paper lines that didn't line up, until you zoomed.

## 0.6.0 (2026-10-29)

The iPad app is now the main OpenPad app. Showing your notes live on the
computer is one of its features.

- **Organized like a binder:** folders of notebooks, notebooks with colored
  sections, and pages with titles, on lined, grid, dot, engineering or blank
  paper.
- **PDFs, scans and photos** become pages you can write on. Importing several
  PDFs at once (OneNote exports, say) makes one notebook with a section per PDF.
- **Search** covers notebook, section and page titles, your handwriting
  (recognized on the iPad) and the text of PDFs.
- **Notes live on the iPad first** and work with no network. Past a storage
  limit (Settings › Storage, 5 GB by default), the notebooks you opened least
  recently are offloaded: they stay in the library with their sections, page
  titles and thumbnail, and download again when you open them. Only notebooks
  the computer already has, files included, are offloaded.
- **A complete copy on the computer,** in a sync folder you choose (default
  `~/Documents/OpenPad`): a folder per notebook and a readable PDF per section.
  The **Sync** button in the bar widget, the share window, the app or
  `openpad sync` brings it up to date.
- **Live:** your strokes appear on the computer while you're still writing
  them, and guests' ink appears on the iPad.
- Fixed: a page only one device had could make its notebook sync again on every
  pass.
