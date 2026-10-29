# Roadmap

Ideas that aren't built yet, roughly in order. Open an issue if you want to
work on one.

## Native apps

- **Mac app.** A small native wrapper (menu-bar item, Dock icon, login item)
  around the same server, so macOS users don't need a terminal. Everything
  OpenPad does already works on macOS through `bin/openpad`. A wrapper mainly
  adds packaging: a signed, notarized `.app` needs an Apple Developer account.
- **Native iPad app.** A SwiftUI and PencilKit app speaking the same sync and
  live-session protocol. It would add the Pencil's barrel double-tap and
  squeeze (web pages can't receive them), lower ink latency, Files integration,
  and sync without a certificate install. Building and installing it needs a
  Mac with Xcode, and distributing it needs the App Store or TestFlight.

## Notes

- Handwriting search (needs on-device recognition).
- Typed text boxes and LaTeX equations.
- Inserting images and photos from the iPad.
- Page templates (Cornell notes, graph paper with axes, music staff).
- Undo history that survives closing the notebook.

## Sync

- Choose the notes folder from the bar widget and the share window.
- Sync over the internet without a tunnel (needs a relay or a peer-to-peer
  transport).
