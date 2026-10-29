import SwiftUI

@main
struct OpenPadApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onChange(of: phase) { _, now in
                    if now == .background { model.backgrounded() }
                    if now == .active { model.syncNow() }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.notebook != nil {
                EditorView()
                    .transition(.opacity)
            } else {
                LibraryView()
                    .transition(.opacity)
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.notebook?.id)
        .animation(.easeInOut(duration: 0.2), value: model.notice)
    }
}

/// Status of the connection to the computer, for the library and the editor.
struct SyncBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.footnote)
        }
    }

    var color: Color {
        switch model.syncState {
        case .ok: return .green
        case .syncing: return .blue
        case .offline, .unpaired: return .red
        case .none: return .secondary
        }
    }

    var text: String {
        let name = model.link?.displayName ?? ""
        switch model.syncState {
        case .none: return "Connect to computer"
        case .syncing: return "Syncing…"
        case .ok: return "Synced with \(name)"
        case .unpaired: return "Key changed · Connect again"
        case .offline: return "Offline · \(name)"
        }
    }
}

/// UIActivityViewController for sharing a file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// A file ready to share, as a sheet item.
struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}
