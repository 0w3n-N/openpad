import CoreImage.CIFilterBuiltins
import SwiftUI

/// Links people can open to watch the notebook live (or draw along) and save
/// it as a PDF. The links come from the computer, which serves the guests.
struct InviteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var info: [String: Any] = [:]
    @State private var canDraw = true
    @State private var error: String?
    @State private var working = false

    private var guests: [String: Any] { info["guests"] as? [String: Any] ?? [:] }
    private var internet: [String: Any] { guests["internet"] as? [String: Any] ?? [:] }
    private var internetOn: Bool { internet["state"] as? String == "on" }
    private var url: String? {
        let kind = canDraw ? "w" : "v"
        return (internetOn ? guests["i" + kind] as? String : nil) ?? guests[kind] as? String
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Anyone with a link sees this notebook live and can save it as a PDF. They can’t open your other notebooks.")
                        .font(.callout)
                    Picker("Link", selection: $canDraw) {
                        Text("Can draw").tag(true)
                        Text("View only").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if let url {
                        HStack {
                            Spacer()
                            if let qr = qrImage(url) {
                                Image(uiImage: qr).interpolation(.none).resizable().frame(width: 200, height: 200)
                            }
                            Spacer()
                        }
                        Text(url).font(.footnote.monospaced()).textSelection(.enabled)
                        ShareLink("Share link", item: URL(string: url)!)
                        Button("Copy link", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = url
                            model.say("Link copied")
                        }
                    } else if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        ProgressView()
                    }
                }
                Section {
                    Toggle("Internet link (for people on other networks)", isOn: Binding(get: { internetOn || internet["state"] as? String == "starting" },
                                                                                         set: { act($0 ? "internet-on" : "internet-off") }))
                        .disabled(working || (internet["available"] as? Bool == false && !internetOn))
                    Text(internetNote).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("New links (disconnects everyone)", role: .destructive) { act("rotate") }
                }
            }
            .navigationTitle("Invite people")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    private var internetNote: String {
        if internet["available"] as? Bool == false { return "Internet links need cloudflared on the computer (its setup can install it)." }
        switch internet["state"] as? String {
        case "starting": return "Starting the internet link…"
        case "error": return internet["error"] as? String ?? "The internet link stopped."
        case "on": return "On. Turn it off when the session ends."
        default: return "Uses a free Cloudflare tunnel while it’s on. Traffic is encrypted but passes through Cloudflare."
        }
    }

    private func load() async {
        guard let link = model.link else {
            error = "Connect to your computer first."
            return
        }
        do {
            info = try await link.json("/api/info")
            if internet["state"] as? String == "starting" {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await load()
            }
        } catch {
            self.error = "The computer is not reachable."
        }
    }

    private func act(_ action: String) {
        guard let link = model.link else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let body = try JSONSerialization.data(withJSONObject: ["action": action])
                info = try await link.json("/api/guests", method: "POST", body: body, headers: ["Content-Type": "application/json"])
                if internet["state"] as? String == "starting" { await load() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
