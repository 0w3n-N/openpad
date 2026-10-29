# OpenPad for iPad (native)

A SwiftUI + PencilKit app that speaks the same sync and live-session
protocol as the web app, so the computer side (Omarchy plugin, share window,
guests, readable PDFs) works unchanged.

What it adds over the web app:

- **Apple Pencil:** PencilKit ink, the system tool palette (pens, highlighter,
  eraser, lasso, ruler), and the Pencil's double-tap and squeeze.
- **No certificate step:** it talks to the computer directly on the local
  network.
- **Background sync:** it keeps syncing for a moment after you leave the app.
- **Vector PDF export:** pages that came from a PDF stay vector.

Layout:

- `OpenPadCore/`: notebooks, the merge rules and the pairing code, as a Swift
  package. It builds on Linux too. Its tests check the merge rules against
  `tests/make_vectors.py`, which comes from `openpad/notebook.py`.
- `OpenPad/`: the app (SwiftUI views, the PencilKit canvas, storage, sync,
  the live session, PDF export).
- `project.yml`: the Xcode project spec, for XcodeGen.

## Getting it onto your iPad

### TestFlight (no Mac needed)

GitHub Actions builds, signs and uploads the app. You need an
[Apple Developer Program](https://developer.apple.com/programs/) membership
(99 USD a year).

1. In [App Store Connect](https://appstoreconnect.apple.com) › Apps, create an
   app: platform iOS, name OpenPad (or any free name), bundle ID
   `io.github.0w3n-n.openpad` (register it under Certificates, IDs & Profiles ›
   Identifiers first if it isn't offered), SKU anything.
2. Users and Access › Integrations › App Store Connect API › Team Keys:
   generate a key with **Admin** access (Xcode needs it to create the signing
   certificate). Download the `.p8` file (you only get one chance), and note
   the Key ID and the Issuer ID.
3. In the GitHub repo › Settings › Secrets and variables › Actions, add:
   - `APP_STORE_CONNECT_KEY_ID`: the Key ID
   - `APP_STORE_CONNECT_ISSUER_ID`: the Issuer ID
   - `APP_STORE_CONNECT_KEY`: the `.p8` file, base64-encoded (`base64 -w0 AuthKey_XXXX.p8`)
   - `APPLE_TEAM_ID`: your Team ID (Membership details on developer.apple.com)
4. Actions › **ios** › Run workflow › tick "Upload a build to TestFlight".
5. When App Store Connect has processed the build (about 10–30 minutes), add
   yourself as a tester under TestFlight › Internal Testing, and install it with
   the TestFlight app on the iPad.

Builds expire after 90 days; run the workflow again for a new one.

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

1. On the computer, switch OpenPad on (it needs 0.5.1 or newer).
2. In the app: **Connect to computer** › scan the QR code from the bar popup or
   the share window's Pair card. Allow local network access when iPadOS asks.
3. Notebooks sync whenever both are on the same network. The notebook you
   open is shown live in the share window; ⋯ › Invite people gives guest
   links.

## Development

- `swift test` in `OpenPadCore/` (Linux or macOS).
- CI (`.github/workflows/ios.yml`) builds the app, runs it in an iPad
  simulator against a real OpenPad server, and checks that it syncs, goes
  live and gets readable PDFs written. It keeps the screenshots.
- Debug builds accept launch arguments for that test: `-openpadDemo YES`,
  `-openpadServer http://127.0.0.1:8770 -openpadKey <key>`, and
  `-openpadOpen YES` (see `OpenPad/App/DemoLaunch.swift`).
