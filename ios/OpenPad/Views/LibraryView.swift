import OpenPadCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var showNew = false
    @State private var showConnect = false
    @State private var showSettings = false
    @State private var importing = false
    @State private var renaming: NotebookEntry?
    @State private var renameText = ""
    @State private var deleting: NotebookEntry?
    @State private var sharing: SharedFile?

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 18)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.library.isEmpty {
                    welcome
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(model.library) { entry in
                            NotebookCard(entry: entry, synced: model.link != nil)
                                .onTapGesture { model.open(entry.id) }
                                .contextMenu {
                                    Button("Rename", systemImage: "pencil") {
                                        renameText = entry.title
                                        renaming = entry
                                    }
                                    Button("Share as PDF", systemImage: "square.and.arrow.up") {
                                        if let url = model.exportNotebookPDF(entry.id) { sharing = SharedFile(url: url) }
                                    }
                                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = entry }
                                }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("OpenPad")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.link == nil ? (showConnect = true) : model.syncNow() } label: { SyncBadge() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Import PDF", systemImage: "doc.badge.plus") { importing = true }
                    Button("New notebook", systemImage: "plus") { showNew = true }
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .sheet(isPresented: $showNew) { NewNotebookView() }
            .sheet(isPresented: $showConnect) { ConnectView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                if case let .success(url) = result { model.importPDF(url, asSection: false) }
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
                Text(model.link == nil ? "This can’t be undone." : "It’s also removed from the computer (kept in its trash folder for a while).")
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
                .padding(.top, 80)
            Text("Welcome to OpenPad").font(.title.bold())
            Text("Notebooks have sections, and sections have pages. Write on lined, grid or blank paper, or on a PDF.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            HStack(spacing: 12) {
                Button("New notebook") { showNew = true }.buttonStyle(.borderedProminent)
                Button("Import a PDF") { importing = true }.buttonStyle(.bordered)
                if model.link == nil { Button("Connect to your computer") { showConnect = true }.buttonStyle(.bordered) }
            }
            .padding(.top, 6)
            if model.link == nil {
                Text("Connecting syncs your notebooks to the computer and shows the open notebook there live, for calls and guests.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

struct NotebookCard: View {
    let entry: NotebookEntry
    let synced: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color(.secondarySystemBackground), Color(.tertiarySystemBackground)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14).fill(.tint).frame(width: 7)
                }
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.separator), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 4) {
                Spacer()
                Text(entry.title).font(.headline).lineLimit(3)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .padding(.leading, 6)
            if synced {
                Circle().fill(entry.dirty ? Color.blue : Color.green).frame(width: 8, height: 8).padding(16).padding(.leading, 6)
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var details: String {
        let secs = entry.sections == 1 ? "1 section" : "\(entry.sections) sections"
        let pages = entry.pages == 1 ? "1 page" : "\(entry.pages) pages"
        let date = Date(timeIntervalSince1970: Double(entry.modified) / 1000)
        return "\(secs) · \(pages) · \(date.formatted(.relative(presentation: .named)))"
    }
}

struct NewNotebookView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var size: PageSize = .letter

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name, e.g. Physics 2A", text: $title)
                Picker("Page size", selection: $size) {
                    Text("Letter (portrait)").tag(PageSize.letter)
                    Text("A4 (portrait)").tag(PageSize.a4)
                    Text("Widescreen (best for calls)").tag(PageSize.wide)
                }
            }
            .navigationTitle("New notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let id = model.createNotebook(title: title, size: size)
                        dismiss()
                        model.open(id)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
