import OpenPadCore
import SwiftUI
import UniformTypeIdentifiers

/// The PencilKit page, bridged into SwiftUI.
struct PageCanvas: UIViewControllerRepresentable {
    let model: AppModel

    func makeUIViewController(context: Context) -> PageCanvasController {
        let c = PageCanvasController(model: model)
        model.canvas = c
        return c
    }

    func updateUIViewController(_ c: PageCanvasController, context: Context) {
        model.canvas = c
        if let id = model.pageID, id != c.pageID { c.show(pageID: id, refit: true, from: model) }
    }
}

struct EditorView: View {
    @Environment(AppModel.self) private var model
    @State private var sidebar = false
    @State private var importing = false
    @State private var showInvite = false
    @State private var showSettings = false
    @State private var exporting: PDFFile?
    @State private var sharing: SharedFile?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            HStack(spacing: 0) {
                if sidebar {
                    SidebarView()
                        .frame(width: 270)
                        .transition(.move(edge: .leading))
                    Divider()
                }
                PageCanvas(model: model)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sidebar)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            if case let .success(url) = result { model.importPDF(url, asSection: true) }
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting, contentType: .pdf, defaultFilename: exporting?.name ?? "OpenPad") { result in
            if case .success = result { model.say("PDF saved") }
        }
        .sheet(isPresented: $showInvite) { InviteView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
        .alert("Rename notebook", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let id = model.notebook?.id { model.rename(id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this page?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete page", role: .destructive) { model.deletePage() }
        }
    }

    // MARK: toolbar

    private var bar: some View {
        HStack(spacing: 4) {
            Button { model.close() } label: { Image(systemName: "chevron.left").frame(width: 38, height: 38) }
                .accessibilityLabel("Notebooks")
            Button { sidebar.toggle() } label: { Image(systemName: "sidebar.left").frame(width: 38, height: 38) }
                .accessibilityLabel("Sections and pages")
            Text(model.notebook?.title ?? "")
                .font(.headline)
                .lineLimit(1)
                .padding(.leading, 6)
            Spacer(minLength: 8)
            Button { model.canvas?.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 38, height: 38) }
                .accessibilityLabel("Undo")
            Button { model.canvas?.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 38, height: 38) }
                .accessibilityLabel("Redo")
            Divider().frame(height: 22).padding(.horizontal, 4)
            Button { model.go(-1) } label: { Image(systemName: "chevron.up").frame(width: 34, height: 38) }
                .disabled(position.index <= 0)
                .accessibilityLabel("Previous page")
            Text(position.label)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 170)
            Button { model.go(1) } label: { Image(systemName: "chevron.down").frame(width: 34, height: 38) }
                .disabled(position.index >= position.count - 1)
                .accessibilityLabel("Next page")
            Button { model.addPage() } label: { Image(systemName: "plus.rectangle.on.rectangle").frame(width: 38, height: 38) }
                .accessibilityLabel("New page after this one")
            paperMenu
            liveBadge
            moreMenu
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var position: (index: Int, count: Int, label: String) {
        guard let nb = model.notebook, let id = model.pageID, let i = nb.order.firstIndex(of: id) else { return (0, 0, "") }
        if nb.layout.sections.count > 1, let sec = nb.section(of: id), let j = sec.pages.firstIndex(of: id) {
            return (i, nb.order.count, "\(sec.title) · \(j + 1)/\(sec.pages.count)")
        }
        return (i, nb.order.count, "\(i + 1) / \(nb.order.count)")
    }

    private var paperMenu: some View {
        Menu {
            Picker("Paper", selection: Binding(get: { model.pageID.flatMap { model.notebook?.pages[$0]?.paper } ?? "blank" },
                                               set: { model.setPaper($0) })) {
                Text("Blank").tag("blank")
                Text("Lines").tag("lines")
                Text("Grid").tag("grid")
                Text("Dots").tag("dots")
                Text("Engineering").tag("eng")
            }
        } label: {
            Image(systemName: "squareshape.split.3x3").frame(width: 38, height: 38)
        }
        .accessibilityLabel("Paper")
    }

    private var liveBadge: some View {
        Button {
            if model.liveReady && model.cast { showInvite = true }
            else if !model.socketConnected { model.say(model.link == nil ? "Connect to your computer first (Settings)." : "Can’t reach \(model.link?.displayName ?? "the computer").") }
            else { model.cast = true; model.castCurrent() }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.liveReady && model.cast ? Color.red : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(liveText).font(.caption)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .opacity(model.link == nil ? 0 : 1)
        .accessibilityLabel(liveText)
    }

    private var liveText: String {
        if model.liveReady && model.cast {
            return model.peers.guests > 0 ? "Live · \(model.peers.guests) guest\(model.peers.guests > 1 ? "s" : "")" : "Live"
        }
        return model.socketConnected ? (model.cast ? "Show" : "Hidden") : "Offline"
    }

    private var moreMenu: some View {
        Menu {
            Button("Import PDF as a new section…", systemImage: "doc.badge.plus") { importing = true }
            Menu("Save as PDF…") {
                Button("This page") { export(.page) }
                Button("This section") { export(.section) }
                Button("Whole notebook") { export(.notebook) }
            }
            Button("Share as PDF…", systemImage: "square.and.arrow.up") {
                if let nb = model.notebook, let url = model.exportPDF(pageIDs: nb.order, title: nb.title) { sharing = SharedFile(url: url) }
            }
            Divider()
            Button("Delete this page", systemImage: "trash", role: .destructive) {
                if (model.notebook?.order.count ?? 0) > 1 { confirmDelete = true } else { model.say("A notebook needs at least one page.") }
            }
            Divider()
            if model.link != nil {
                Toggle("Show on the computer", isOn: Binding(get: { model.cast }, set: { model.cast = $0 }))
                Button("Invite people…", systemImage: "person.2") { showInvite = true }
                Button(model.liveWindow == "idle" ? "Annotate a desktop window…" : "Stop the live window", systemImage: "macwindow") {
                    model.toggleWindowAnnotation()
                }
                Button("Remove guests’ ink on this page", systemImage: "eraser") { model.clearGuestInk() }
                Divider()
            }
            Button("Rename notebook…", systemImage: "pencil") {
                renameText = model.notebook?.title ?? ""
                renaming = true
            }
            Button("Fit page", systemImage: "arrow.up.left.and.arrow.down.right") { model.canvas?.resetZoom() }
            Button("Settings…", systemImage: "gearshape") { showSettings = true }
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: 38, height: 38)
        }
        .accessibilityLabel("More")
    }

    private enum Scope { case page, section, notebook }

    private func export(_ scope: Scope) {
        guard let nb = model.notebook, let id = model.pageID else { return }
        let ids: [String], title: String
        switch scope {
        case .page:
            ids = [id]
            title = "\(nb.title) - page \((nb.order.firstIndex(of: id) ?? 0) + 1)"
        case .section:
            let sec = nb.section(of: id)
            ids = sec?.pages ?? [id]
            title = "\(nb.title) - \(sec?.title ?? "")"
        case .notebook:
            ids = nb.order
            title = nb.title
        }
        if let url = model.exportPDF(pageIDs: ids, title: title), let data = try? Data(contentsOf: url) {
            exporting = PDFFile(data: data, name: title)
        }
    }
}

/// A PDF for .fileExporter, so you choose the folder it goes to.
struct PDFFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    let data: Data
    let name: String

    init(data: Data, name: String) {
        self.data = data
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        name = "OpenPad"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
