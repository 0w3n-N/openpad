import OpenPadCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// What the library is showing.
enum Shelf: Hashable {
    case recent
    case all
    case folder(String)
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var shelf: Shelf? = .recent
    @State private var query = ""
    @State private var showNew = false
    @State private var showConnect = false
    @State private var showSettings = false
    @State private var importing = false
    @State private var newFolder: String?  // parent of a folder being made
    @State private var folderName = ""
    @State private var renamingFolder: String?
    @State private var renaming: NotebookEntry?
    @State private var renameText = ""
    @State private var moving: NotebookEntry?
    @State private var deleting: NotebookEntry?
    @State private var sharing: SharedFile?

    private var currentFolder: String {
        if case let .folder(f) = shelf { return f }
        return ""
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                detail
                    .navigationTitle(title)
                    .toolbar { toolbar }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search notes, handwriting, PDFs")
        .sheet(isPresented: $showNew) { NewNotebookView(folder: currentFolder) }
        .sheet(isPresented: $showConnect) { ConnectView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
        .sheet(item: $moving) { entry in FolderPicker(title: "Move “\(entry.title)”", current: entry.folder) { model.move(entry.id, toFolder: $0) } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result, !urls.isEmpty { model.importPDFs(urls, folder: currentFolder) }
        }
        .alert("New folder", isPresented: Binding(get: { newFolder != nil }, set: { if !$0 { newFolder = nil } })) {
            TextField("e.g. 2025 Fall", text: $folderName)
            Button("Create") {
                model.createFolder(folderName, in: newFolder ?? "")
                let path = AppModel.cleanFolder((newFolder ?? "").isEmpty ? folderName : "\(newFolder!)/\(folderName)")
                if !path.isEmpty { shelf = .folder(path) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename folder", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField("Name", text: $folderName)
            Button("Rename") { if let f = renamingFolder { model.renameFolder(f, to: folderName); shelf = .all } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename notebook", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let e = renaming { model.rename(e.id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let e = deleting { model.delete(e.id) } }
        } message: {
            Text(model.link == nil ? "This can’t be undone." : "It’s also removed from the computer’s sync folder (kept in OpenPad’s trash there for a while).")
        }
    }

    // MARK: sidebar

    private var sidebar: some View {
        List(selection: $shelf) {
            Section {
                Label("Recent", systemImage: "clock").tag(Shelf.recent)
                Label("All Notebooks", systemImage: "books.vertical").tag(Shelf.all)
            }
            Section {
                ForEach(model.folders, id: \.self) { folder in
                    let depth = folder.filter { $0 == "/" }.count
                    Label(String(folder.split(separator: "/").last ?? ""), systemImage: "folder")
                        .padding(.leading, CGFloat(depth) * 14)
                        .tag(Shelf.folder(folder))
                        .contextMenu {
                            Button("New folder inside", systemImage: "folder.badge.plus") {
                                folderName = ""
                                newFolder = folder
                            }
                            Button("Rename", systemImage: "pencil") {
                                folderName = String(folder.split(separator: "/").last ?? "")
                                renamingFolder = folder
                            }
                            Button("Delete (if empty)", systemImage: "trash", role: .destructive) {
                                if !model.deleteFolder(folder) { model.say("Move its notebooks out first.") }
                                else if shelf == .folder(folder) { shelf = .all }
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button {
                        folderName = ""
                        newFolder = ""
                    } label: { Image(systemName: "folder.badge.plus") }
                    .accessibilityLabel("New folder")
                }
            }
            Section {
                Button { model.link == nil ? (showConnect = true) : model.syncNow() } label: { SyncBadge() }
                if model.storageLimitMB > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(model.bytesUsed), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(model.storageLimitMB) * 1_048_576, countStyle: .file)) on this iPad")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("OpenPad")
    }

    // MARK: detail

    private var title: String {
        if !query.isEmpty { return "Search" }
        switch shelf ?? .recent {
        case .recent: return "Recent"
        case .all: return "All Notebooks"
        case let .folder(f): return String(f.split(separator: "/").last ?? "")
        }
    }

    private var shown: [NotebookEntry] {
        switch shelf ?? .recent {
        case .recent:
            return model.library.sorted { max($0.lastOpened, $0.modified) > max($1.lastOpened, $1.modified) }.prefix(24).map { $0 }
        case .all:
            return model.library.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case let .folder(f):
            return model.library.filter { $0.folder == f }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    private var subfolders: [String] {
        guard case let .folder(f) = shelf ?? .recent else { return [] }
        return model.folders.filter { $0.hasPrefix(f + "/") && !$0.dropFirst(f.count + 1).contains("/") }
    }

    @ViewBuilder
    private var detail: some View {
        if !query.isEmpty {
            SearchResults(query: query)
        } else if model.library.isEmpty {
            welcome
        } else {
            ScrollView {
                if !subfolders.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                        ForEach(subfolders, id: \.self) { f in
                            Button { shelf = .folder(f) } label: {
                                Label(String(f.split(separator: "/").last ?? ""), systemImage: "folder.fill")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding([.horizontal, .top], 20)
                }
                if shown.isEmpty {
                    Text("No notebooks here yet. Make one with +, or move one here (touch and hold it › Move to folder).")
                        .foregroundStyle(.secondary)
                        .padding(40)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 250), spacing: 18)], spacing: 22) {
                    ForEach(shown) { entry in
                        NotebookCard(entry: entry, connected: model.link != nil, busy: model.downloading.contains(entry.id))
                            .onTapGesture { model.open(entry.id) }
                            .contextMenu { menu(entry) }
                    }
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private func menu(_ entry: NotebookEntry) -> some View {
        Button("Open", systemImage: "book") { model.open(entry.id) }
        Button("Rename", systemImage: "pencil") {
            renameText = entry.title
            renaming = entry
        }
        Button("Move to folder…", systemImage: "folder") { moving = entry }
        if model.link != nil {
            if entry.offloaded {
                Button("Download", systemImage: "icloud.and.arrow.down") { model.open(entry.id) }
            } else {
                Button("Remove download (keep on computer)", systemImage: "icloud.and.arrow.up") { model.removeDownload(entry.id) }
            }
            Toggle("Keep on this iPad", systemImage: "pin", isOn: Binding(get: { entry.keep }, set: { model.setKeep(entry.id, $0) }))
        }
        Button("Share as PDF", systemImage: "square.and.arrow.up") {
            if let url = model.exportNotebookPDF(entry.id) { sharing = SharedFile(url: url) }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = entry }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Import PDFs", systemImage: "doc.badge.plus") { importing = true }
            Button("New notebook", systemImage: "plus") { showNew = true }
            Button("Settings", systemImage: "gearshape") { showSettings = true }
        }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
                .padding(.top, 80)
            Text("Welcome to OpenPad").font(.title.bold())
            Text("Folders hold notebooks (one per class, say), notebooks have sections, and sections have pages. Write on lined, grid or engineering paper, or on PDFs.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            HStack(spacing: 12) {
                Button("New notebook") { showNew = true }.buttonStyle(.borderedProminent)
                Button("Import PDFs") { importing = true }.buttonStyle(.bordered)
                if model.link == nil { Button("Connect to your computer") { showConnect = true }.buttonStyle(.bordered) }
            }
            .padding(.top, 6)
            Text("Moving from OneNote? Export each notebook or section as a PDF there, then import the PDFs here: each becomes a section you can write on.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

struct NotebookCard: View {
    @Environment(AppModel.self) private var model
    let entry: NotebookEntry
    let connected: Bool
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let cover = entry.cover, let image = model.store.thumbnail(cover) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [Color(.secondarySystemBackground), Color(.tertiarySystemBackground)], startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipped()
                .opacity(entry.offloaded ? 0.55 : 1)
                .overlay(alignment: .leading) { Rectangle().fill(.tint).frame(width: 6) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 0.5))
                HStack(spacing: 4) {
                    if busy { ProgressView().controlSize(.small) }
                    if entry.keep { Image(systemName: "pin.fill") }
                    if entry.offloaded { Image(systemName: "icloud.and.arrow.down") }
                    if connected && !entry.offloaded { Circle().fill(entry.dirty ? Color.blue : Color.green).frame(width: 8, height: 8) }
                }
                .font(.caption)
                .padding(6)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
            }
            Text(entry.title).font(.headline).lineLimit(2)
            Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var details: String {
        let secs = entry.sections == 1 ? "1 section" : "\(entry.sections) sections"
        let pages = entry.pages == 1 ? "1 page" : "\(entry.pages) pages"
        let date = Date(timeIntervalSince1970: Double(entry.modified) / 1000)
        let place = entry.offloaded ? " · on computer" : ""
        return "\(secs) · \(pages) · \(date.formatted(.relative(presentation: .named)))\(place)"
    }
}

/// Search across every notebook: titles, recognized handwriting, PDF text.
struct SearchResults: View {
    @Environment(AppModel.self) private var model
    let query: String

    var body: some View {
        let hits = model.text.search(query, notebooks: model.library)
        List {
            if hits.isEmpty {
                Text("Nothing found for “\(query)”.").foregroundStyle(.secondary)
            }
            ForEach(hits) { hit in
                Button {
                    model.open(hit.nb, page: hit.page)
                } label: {
                    HStack(spacing: 12) {
                        if let page = hit.page, let image = model.store.thumbnail(page) {
                            Image(uiImage: image).resizable().scaledToFit().frame(width: 44, height: 58)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Image(systemName: "book.closed").frame(width: 44, height: 58)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Text("Handwriting is recognized on this iPad as you write, so new pages appear here after a moment.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Pick (or make) a folder.
struct FolderPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let title: String
    let current: String
    let pick: (String) -> Void
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Button { choose("") } label: { row("Top level (no folder)", selected: current.isEmpty) }
                ForEach(model.folders, id: \.self) { f in
                    Button { choose(f) } label: { row(f.replacingOccurrences(of: "/", with: " › "), selected: f == current) }
                }
                Section("New folder") {
                    HStack {
                        TextField("e.g. 2025 Fall/ECE 210", text: $newName)
                        Button("Move here") {
                            let f = AppModel.cleanFolder(newName)
                            guard !f.isEmpty else { return }
                            model.createFolder(f, in: "")
                            choose(f)
                        }
                        .disabled(AppModel.cleanFolder(newName).isEmpty)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row(_ text: String, selected: Bool) -> some View {
        HStack {
            Label(text, systemImage: "folder")
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
        .contentShape(Rectangle())
    }

    private func choose(_ f: String) {
        pick(f)
        dismiss()
    }
}

struct NewNotebookView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: String
    @State private var title = ""
    @State private var size: PageSize = .letter

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name, e.g. ECE 210 Signals", text: $title)
                Picker("Page size", selection: $size) {
                    Text("Letter (portrait)").tag(PageSize.letter)
                    Text("A4 (portrait)").tag(PageSize.a4)
                    Text("Widescreen (best for calls)").tag(PageSize.wide)
                }
                if !folder.isEmpty {
                    LabeledContent("Folder", value: folder.replacingOccurrences(of: "/", with: " › "))
                }
            }
            .navigationTitle("New notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let id = model.createNotebook(title: title, size: size, folder: folder)
                        dismiss()
                        model.open(id)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
