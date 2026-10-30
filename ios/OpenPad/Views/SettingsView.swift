import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = false
    @State private var confirmForget = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Writing") {
                    Toggle("Draw with your finger too", isOn: $model.fingerDrawing)
                    Text("""
                    Pens, colors, widths, the eraser, the lasso and the ruler are in the tool palette. \
                    Pick the Monoline pen for lines that don’t change with pressure. Double-tap (or squeeze) \
                    the Apple Pencil to switch tools; choose what it does in Settings › Apple Pencil.
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Section("Computer") {
                    if let link = model.link {
                        LabeledContent("Connected to", value: link.displayName)
                        LabeledContent("Address", value: link.base.host.map { "\($0):\(link.base.port ?? 8770)" } ?? "")
                        HStack {
                            Text("Status")
                            Spacer()
                            SyncBadge()
                        }
                        Button("Sync now") { model.syncNow() }
                        Button("Connect to another computer…") { connecting = true }
                        Button("Forget this computer", role: .destructive) { confirmForget = true }
                    } else {
                        Text("Not connected. Notebooks stay on this iPad until you connect it to a computer running OpenPad.")
                            .font(.callout)
                        Button("Connect to a computer…") { connecting = true }
                    }
                    Text("The computer keeps a complete copy of every notebook, with a readable PDF of each section, in its sync folder (Documents/OpenPad unless you chose another there). The notebook you open is shown live on it (turn that off in the editor’s ⋯ menu).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Storage on this iPad") {
                    LabeledContent("OpenPad uses", value: ByteCountFormatter.string(fromByteCount: Int64(model.bytesUsed), countStyle: .file))
                    Picker("Keep up to", selection: $model.storageLimitMB) {
                        Text("1 GB").tag(1024)
                        Text("2 GB").tag(2048)
                        Text("5 GB").tag(5120)
                        Text("10 GB").tag(10240)
                        Text("20 GB").tag(20480)
                        Text("50 GB").tag(51200)
                        Text("No limit").tag(0)
                    }
                    Text("Past this (or when the iPad runs low on space), the notebooks you opened least recently are offloaded: they stay in your library with their sections, page titles and thumbnails, and download again when you open them on the same Wi-Fi as your computer. Only notebooks the computer already has are offloaded. Touch and hold a notebook to keep it on this iPad, or to offload it now.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    if model.link != nil {
                        Button("Free up space now") { model.enforceStorageLimit(force: true) }
                    }
                }
                Section("Sync") {
                    Toggle("Sync automatically", isOn: $model.autoSync)
                    Text(model.autoSync
                         ? "Notebooks sync whenever the computer is reachable, and when you leave the app."
                         : "Notebooks sync only when you press Sync (here or on the computer). The notebook shown live on the computer is still sent there.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Link("OpenPad on GitHub", destination: URL(string: "https://github.com/0w3n-N/openpad")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $connecting) { ConnectView() }
            .confirmationDialog("Forget this computer?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { model.setLink(nil) }
            } message: {
                Text("Your notebooks stay on this iPad. Connect again by scanning the computer’s QR code.")
            }
        }
    }
}
