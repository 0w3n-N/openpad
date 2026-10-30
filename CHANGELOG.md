# Changelog

Each version is released on GitHub with the iPad app (`OpenPad.ipa`, for
SideStore). The computer side updates with `omarchy plugin update`. For
versions before 0.6.0 (Inkcast, OpenPad 0.5), see the git history.

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
