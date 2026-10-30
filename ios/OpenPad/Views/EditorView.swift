import OpenPadCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The page and its ink, bridged into SwiftUI.
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
    @State private var importAsSection = false
    @State private var scanning = false
    @State private var pickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var titling = false
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
            ToolRow()
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
            guard case let .success(url) = result else { return }
            if importAsSection { model.importPDFAsSection(url) } else { model.insertPDFPages(url) }
        }
        .fullScreenCover(isPresented: $scanning) {
            DocumentScanner { images in
                scanning = false
                if !images.isEmpty { model.insertImages(images) }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photos, maxSelectionCount: 30, matching: .images)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            Task {
                let images = await loadImages(items)
                photos = []
                if !images.isEmpty { model.insertImages(images) }
            }
        }
        .alert("Page title", isPresented: $titling) {
            TextField("e.g. Lecture 4: Laplace transforms", text: $renameText)
            Button("Save") { if let id = model.pageID { model.setPageTitle(id, renameText) } }
            Button("Cancel", role: .cancel) {}
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
            Button {
                renameText = pageTitle
                titling = true
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.notebook?.title ?? "").font(.headline).lineLimit(1)
                    Text(pageTitle.isEmpty ? "Add a page title" : pageTitle)
                        .font(.caption)
                        .foregroundStyle(pageTitle.isEmpty ? .tertiary : .secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            .accessibilityLabel("Page title")
            Spacer(minLength: 8)
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
            insertMenu
            paperMenu
            liveBadge
            moreMenu
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var pageTitle: String {
        model.pageID.flatMap { model.notebook?.pages[$0]?.title } ?? ""
    }

    private var insertMenu: some View {
        Menu {
            Button("Blank page after this", systemImage: "doc") { model.addPage() }
            Button("PDF pages after this…", systemImage: "doc.on.doc") {
                importAsSection = false
                importing = true
            }
            Button("PDF as a new section…", systemImage: "doc.badge.plus") {
                importAsSection = true
                importing = true
            }
            if DocumentScanner.isAvailable {
                Button("Scan documents…", systemImage: "doc.viewfinder") { scanning = true }
            }
            Button("Photos…", systemImage: "photo.on.rectangle") { pickingPhotos = true }
        } label: {
            Image(systemName: "plus.rectangle.on.rectangle").frame(width: 38, height: 38)
        } primaryAction: {
            model.addPage()
        }
        .accessibilityLabel("New page (hold for more)")
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

/// The drawing tools, as in the web app: pen, highlighter, eraser, select and
/// move, shapes; colors; widths; undo and redo.
struct ToolRow: View {
    @Environment(AppModel.self) private var model
    @State private var choosingShape = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tool(.pen, "pencil.tip", "Pen")
                tool(.highlighter, "highlighter", "Highlighter")
                tool(.eraser, "eraser", "Eraser")
                tool(.lasso, "lasso", "Select and move")
                shapeButton
                divider
                ForEach(Ink.colors, id: \.self) { c in
                    Button { model.pickColor(c) } label: {
                        Circle()
                            .fill(Color(UIColor(hex: c)))
                            .overlay(Circle().strokeBorder(Color.secondary.opacity(c == "#ffffff" ? 0.6 : 0.2), lineWidth: 1))
                            .frame(width: 24, height: 24)
                            .padding(4)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: model.color == c ? 2.5 : 0))
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Color \(c)")
                    .accessibilityAddTraits(model.color == c ? .isSelected : [])
                }
                divider
                ForEach(Array(Ink.widths.enumerated()), id: \.offset) { i, w in
                    Button { model.width = w } label: {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: [5.0, 9, 14][i], height: [5.0, 9, 14][i])
                            .frame(width: 34, height: 34)
                            .background(model.width == w ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(["Fine", "Medium", "Bold"][i])
                    .accessibilityAddTraits(model.width == w ? .isSelected : [])
                }
                divider
                Button { model.canvas?.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 38, height: 34) }
                    .disabled(!model.canUndo)
                    .accessibilityLabel("Undo")
                Button { model.canvas?.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 38, height: 34) }
                    .disabled(!model.canRedo)
                    .accessibilityLabel("Redo")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
        }
        .background(.bar)
    }

    private var divider: some View {
        Divider().frame(height: 22).padding(.horizontal, 6)
    }

    private func tool(_ t: InkTool, _ icon: String, _ label: String) -> some View {
        Button { model.setTool(t) } label: {
            Image(systemName: icon)
                .font(.system(size: 17))
                .frame(width: 38, height: 34)
                .background(model.tool == t ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(model.tool == t ? .isSelected : [])
    }

    private static func icon(_ s: Ink.Shape) -> String {
        switch s {
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .ellipse: return "oval"
        case .axes: return "chart.xyaxis.line"
        }
    }

    private static func name(_ s: Ink.Shape) -> String {
        switch s {
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rect: return "Box"
        case .ellipse: return "Ellipse"
        case .axes: return "Axes"
        }
    }

    /// Picks the shape tool; tapped again, chooses the shape.
    private var shapeButton: some View {
        Button {
            if model.tool == .shape { choosingShape = true } else { model.setTool(.shape) }
        } label: {
            Image(systemName: Self.icon(model.shape))
                .font(.system(size: 17))
                .frame(width: 38, height: 34)
                .background(model.tool == .shape ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel("Shapes: \(Self.name(model.shape))")
        .accessibilityAddTraits(model.tool == .shape ? .isSelected : [])
        .popover(isPresented: $choosingShape) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Ink.Shape.allCases, id: \.self) { s in
                    Button {
                        model.shape = s
                        choosingShape = false
                    } label: {
                        Label(Self.name(s), systemImage: Self.icon(s))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(model.shape == s ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                Text("Tip: hold the Pencil still at the end of a stroke to straighten it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            .padding(8)
            .frame(width: 260)
            .presentationCompactAdaptation(.popover)
        }
    }
}
