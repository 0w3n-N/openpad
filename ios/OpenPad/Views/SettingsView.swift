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
                    Text("Connected, notebooks sync whenever you’re on the same network, and readable PDFs go to the computer’s Documents/OpenPad folder. The notebook you open is shown live there (turn that off in the editor’s ⋯ menu).")
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
