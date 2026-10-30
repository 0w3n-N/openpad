import OpenPadCore
import SwiftUI

/// Section tab colors (stored as #rrggbb, so every device shows the same).
let sectionColors: [(String, String)] = [
    ("Red", "#e5484d"), ("Orange", "#f76b15"), ("Yellow", "#ffc53d"), ("Green", "#30a46c"),
    ("Teal", "#12a594"), ("Blue", "#3e63dd"), ("Purple", "#8e4ec6"), ("Pink", "#d6409f"),
]

/// Sections (colored tabs) and the pages of the selected one, with titles.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?  // section shown in the page list
    @State private var renamingSection: OpenPadCore.Section?
    @State private var renamingPage: String?
    @State private var newSection = false
    @State private var text = ""
    @State private var deleting: OpenPadCore.Section?

    private var sections: [OpenPadCore.Section] { model.notebook?.layout.sections ?? [] }
    private var current: OpenPadCore.Section? {
        let id = selected ?? model.pageID.flatMap { model.notebook?.section(of: $0)?.id }
        return sections.first { $0.id == id } ?? sections.first
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionList
                .frame(maxHeight: 260)
            Divider()
            pageList
        }
        .background(Color(.secondarySystemBackground))
        .onChange(of: model.pageID) { _, _ in selected = nil }
        .alert("New section", isPresented: $newSection) {
            TextField("e.g. Homework", text: $text)
            Button("Add") { model.addSection(text.isEmpty ? "Section" : text) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename section", isPresented: Binding(get: { renamingSection != nil }, set: { if !$0 { renamingSection = nil } })) {
            TextField("Name", text: $text)
            Button("Rename") { if let s = renamingSection { model.renameSection(s.id, to: text) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Page title", isPresented: Binding(get: { renamingPage != nil }, set: { if !$0 { renamingPage = nil } })) {
            TextField("e.g. Lecture 4: Laplace transforms", text: $text)
            Button("Save") { if let p = renamingPage { model.setPageTitle(p, text) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")” and its pages?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete section", role: .destructive) { if let s = deleting { model.deleteSection(s.id) } }
        }
    }

    // MARK: sections

    private var sectionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Sections").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        text = ""
                        newSection = true
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New section")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                ForEach(Array(sections.enumerated()), id: \.element.id) { i, sec in
                    Button {
                        selected = sec.id
                        if !(model.pageID.map(sec.pages.contains) ?? false) { model.show(sec.pages.first) }
                    } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(sec.color.map { Color(UIColor(hex: $0)) } ?? Color.gray.opacity(0.5))
                                .frame(width: 5, height: 22)
                            Text(sec.title).lineLimit(1)
                            Spacer()
                            Text("\(sec.pages.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(current?.id == sec.id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                    .contextMenu { sectionMenu(sec, index: i) }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionMenu(_ sec: OpenPadCore.Section, index: Int) -> some View {
        Button("Rename", systemImage: "pencil") {
            text = sec.title
            renamingSection = sec
        }
        Menu("Color") {
            ForEach(sectionColors, id: \.1) { name, hex in
                Button(name) { model.setSectionColor(sec.id, hex) }
            }
            Button("None") { model.setSectionColor(sec.id, nil) }
        }
        Button("Add a page", systemImage: "plus") { model.addPage(after: sec.pages.last) }
        if index > 0 { Button("Move up", systemImage: "arrow.up") { model.moveSection(sec.id, by: -1) } }
        if index < sections.count - 1 { Button("Move down", systemImage: "arrow.down") { model.moveSection(sec.id, by: 1) } }
        if sections.count > 1 { Button("Delete", systemImage: "trash", role: .destructive) { deleting = sec } }
    }

    // MARK: pages

    private var pageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(current?.title ?? "Pages").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button { model.addPage(after: current?.pages.last) } label: { Image(systemName: "plus") }
                            .accessibilityLabel("New page")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    if let sec = current {
                        ForEach(Array(sec.pages.enumerated()), id: \.element) { i, pid in
                            PageRow(pageID: pid, number: i + 1, selected: model.pageID == pid)
                                .id(pid)
                                .onTapGesture { model.show(pid) }
                                .contextMenu { pageMenu(pid, sec: sec, index: i) }
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .onAppear { if let id = model.pageID { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    @ViewBuilder
    private func pageMenu(_ pid: String, sec: OpenPadCore.Section, index: Int) -> some View {
        Button("Title…", systemImage: "character.cursor.ibeam") {
            text = model.notebook?.pages[pid]?.title ?? ""
            renamingPage = pid
        }
        Button("New page after this", systemImage: "plus") { model.addPage(after: pid) }
        if index > 0 { Button("Move up", systemImage: "arrow.up") { model.movePage(pid, by: -1) } }
        if index < sec.pages.count - 1 { Button("Move down", systemImage: "arrow.down") { model.movePage(pid, by: 1) } }
        if sections.count > 1 {
            Menu("Move to section") {
                ForEach(sections.filter { $0.id != sec.id }) { other in
                    Button(other.title) { model.movePage(pid, toSection: other.id) }
                }
            }
        }
        if (model.notebook?.order.count ?? 0) > 1 {
            Button("Delete page", systemImage: "trash", role: .destructive) { model.deletePage(pid) }
        }
    }
}

struct PageRow: View {
    @Environment(AppModel.self) private var model
    let pageID: String
    let number: Int
    let selected: Bool

    var body: some View {
        let page = model.notebook?.pages[pageID]
        HStack(spacing: 10) {
            Group {
                if let page {
                    Image(uiImage: ThumbCache.shared.image(page, store: model.store))
                        .resizable()
                        .aspectRatio(CGFloat(page.w / page.h), contentMode: .fit)
                }
            }
            .frame(width: 46, height: 58)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(.separator), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(page.map { $0.title.isEmpty ? "Page \(number)" : $0.title } ?? "")
                    .font(.subheadline)
                    .foregroundStyle(page?.title.isEmpty ?? true ? Color.secondary : Color.primary)
                    .lineLimit(2)
                if let page, page.bg?.pdf != nil {
                    Text("PDF page \(page.bg?.n ?? 0)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Thumbnails of the open notebook's pages, redrawn only when a page changes.
@MainActor
final class ThumbCache {
    static let shared = ThumbCache()
    private var items: [String: (key: String, image: UIImage)] = [:]

    func image(_ page: Page, store: Store) -> UIImage {
        let key = "\(page.t).\(page.strokes.count).\(page.strokes.last?.id ?? "").\(page.gone.count)"
        if let hit = items[page.id], hit.key == key { return hit.image }
        let img = PageRenderer.thumbnail(page, width: 120, store: store)
        items[page.id] = (key, img)
        if items.count > 400 { items.removeAll() }
        return img
    }
}
