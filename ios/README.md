# OpenPad for iPad (native)

The main OpenPad app: a notes app for iPad and Apple Pencil, built with
SwiftUI and PencilKit. The computer side (Omarchy plugin, share window, guests,
sync folder) works with it unchanged, over the same protocol as the web app.

## How it's organized

- **Folders** hold notebooks: a folder per semester, a notebook per class,
  for example. Folders can nest (`2025 Fall/ECE 210`).
- **Notebooks** have **sections**, which are colored tabs (Lectures,
  Homework, Labs), and sections have **pages**. Each page can have a title.
- **Pages** are lined, grid, dot, engineering or blank paper, or a page of
  a PDF, a scan or a photo.
- **Search** covers notebook, section and page titles, your handwriting
  (recognized on the iPad by Apple's Vision framework) and the text of PDFs.

Writing uses Apple's tool palette: pens, highlighter, eraser, lasso and ruler.
Double-tapping or squeezing the Pencil switches tools, as set in Settings ›
Apple Pencil.

## Where your notes live

- **On the iPad, first.** Notebooks are stored in the app and work with no
  network at all.
- **A complete copy on your computer.** Whenever the iPad can reach the
  computer, notebooks sync both ways. The computer keeps everything in its
  sync folder: one folder per notebook, a readable PDF per section, and the
  notebook itself with its files. Press **Sync** in the Omarchy bar widget,
  the share window or the app to bring the copy up to date on demand. To sync
  only when you press Sync, turn off Settings › Sync automatically.
- **Offloading.** Settings › Storage sets how much OpenPad keeps on the iPad
  (5 GB by default). Past that, or when the iPad is low on space, the
  notebooks you opened least recently are offloaded: they stay in the library
  with their sections, page titles, thumbnails and search text, and download
  again when you open one on the same Wi-Fi as the computer. Only notebooks
  the computer already has, files included, are ever offloaded. Touch and hold
  a notebook to keep it on the iPad, or to offload it right away.

## Moving from OneNote

Export each OneNote notebook or section as a PDF (File › Export in OneNote),
then use **Import PDFs** in the library. Each PDF becomes a section whose pages
you can write on, and the whole set becomes one notebook.

## Code

- `OpenPadCore/`: notebooks, the merge rules and the pairing code, as a Swift
  package. It builds on Linux too. Its tests check the merge rules against
  `tests/make_vectors.py`, which comes from `openpad/notebook.py`.
- `OpenPad/`: the app: library and search, the PencilKit editor, storage and
  offloading, sync, the live session and PDF export.
- `project.yml`: the Xcode project spec, for XcodeGen.

## Getting it onto your iPad

### With a Mac

```bash
brew install xcodegen
cd ios && xcodegen generate && open OpenPad.xcodeproj
```

Select your team under Signing & Capabilities, plug in the iPad, and Run.
With a free Apple ID the app has to be reinstalled every 7 days.

### Sideloading (AltStore, SideStore)

Every CI run keeps an unsigned build: Actions › ios › the latest run ›
Artifacts › **OpenPad-unsigned-ipa**. AltStore or SideStore sign it with
your Apple ID when installing. With a free Apple ID, apps are re-signed
every 7 days.

## Using it

1. On the computer, switch OpenPad on (it needs 0.6 or newer).
2. In the app: **Connect to computer** › scan the QR code from the bar popup or
   the share window's Pair card. Allow local network access when iPadOS asks.
3. The notebook you open is shown live in the share window, stroke by stroke
   as you write. ⋯ › Invite people gives guest links.

## Development

- `swift test` in `OpenPadCore/` (Linux or macOS).
- CI (`.github/workflows/ios.yml`) builds the app and runs it in an iPad
  simulator against a real OpenPad server. It checks that:
  - notebooks sync into the computer's folders
  - strokes travel live both ways (from the iPad, and from a guest)
  - the Sync button works and produces readable PDFs
  - offloading keeps the outline, and opening downloads everything again

  It keeps the screenshots.
- Debug builds accept launch arguments for that test: `-openpadDemo YES`,
  `-openpadServer http://127.0.0.1:8770 -openpadKey <key>`, and
  `-openpadOpen YES`, `-openpadDrawTest YES`, `-openpadOffloadAll YES` (see
  `OpenPad/App/DemoLaunch.swift`).
