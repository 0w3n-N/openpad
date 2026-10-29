# Roadmap

Ideas that aren't built yet, roughly in order. Open an issue if you want to
work on one.

## Native apps

- **Mac app.** A small native wrapper (menu-bar item, Dock icon, login item)
  around the same server, so macOS users don't need a terminal. Everything
  OpenPad does already works on macOS through `bin/openpad`. A wrapper mainly
  adds packaging: a signed, notarized `.app` needs an Apple Developer account.
- **Native iPad app.** In progress in `ios/` (SwiftUI + PencilKit, same
  protocol). Next: shapes and straight-line snapping, continuous scrolling,
  text boxes, and live preview of strokes while they're being drawn.

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
