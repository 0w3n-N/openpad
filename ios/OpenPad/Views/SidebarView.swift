import OpenPadCore
import SwiftUI

/// Sections and their pages, OneNote-style.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: OpenPadCore.Section?
    @State private var newSection = false
    @State private var text = ""
    @State private var deleting: OpenPadCore.Section?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Sections").font(.headline)
                        Spacer()
                        Button("Section", systemImage: "plus") {
                            text = "Lecture"
                            newSection = true
                        }
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline)
                    }
                    ForEach(model.notebook?.layout.sections ?? []) { sec in
                        sectionView(sec)
                    }
                }
                .padding(12)
            }
            .onAppear { if let id = model.pageID { proxy.scrollTo(id, anchor: .center) } }
        }
        .background(Color(.secondarySystemBackground))
        .alert("New section", isPresented: $newSection) {
            TextField("Name", text: $text)
            Button("Add") { model.addSection(text.isEmpty ? "Section" : text) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename section", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $text)
            Button("Rename") { if let s = renaming { model.renameSection(s.id, to: text) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")” and its pages?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete section", role: .destructive) { if let s = deleting { model.deleteSection(s.id) } }
        }
    }

    @ViewBuilder
    private func sectionView(_ sec: OpenPadCore.Section) -> some View {
        let sections = model.notebook?.layout.sections ?? []
        let index = sections.firstIndex(where: { $0.id == sec.id }) ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        text = sec.title
                        renaming = sec
                    }
                    Button("Add a page", systemImage: "plus") { model.addPage(after: sec.pages.last) }
                    if index > 0 { Button("Move up", systemImage: "arrow.up") { model.moveSection(sec.id, by: -1) } }
                    if index < sections.count - 1 { Button("Move down", systemImage: "arrow.down") { model.moveSection(sec.id, by: 1) } }
                    if sections.count > 1 { Button("Delete", systemImage: "trash", role: .destructive) { deleting = sec } }
                } label: {
                    Text(sec.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Spacer()
                Button { model.addPage(after: sec.pages.last) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a page to \(sec.title)")
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Array(sec.pages.enumerated()), id: \.element) { i, pid in
                    PageThumb(pageID: pid, number: i + 1)
                        .id(pid)
                        .onTapGesture { model.show(pid) }
                        .contextMenu {
                            ForEach(sections.filter { $0.id != sec.id }) { other in
                                Button("Move to \(other.title)") { model.movePage(pid, toSection: other.id) }
                            }
                            Button("Delete page", systemImage: "trash", role: .destructive) { model.deletePage(pid) }
                        }
                }
            }
        }
    }
}

struct PageThumb: View {
    @Environment(AppModel.self) private var model
    let pageID: String
    let number: Int

    var body: some View {
        let page = model.notebook?.pages[pageID]
        ZStack(alignment: .bottomTrailing) {
            if let page {
                Image(uiImage: ThumbCache.shared.image(page, store: model.store))
                    .resizable()
                    .aspectRatio(CGFloat(page.w / page.h), contentMode: .fit)
            }
            Text("\(number)").font(.caption2).foregroundStyle(.gray).padding(3)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(model.pageID == pageID ? Color.accentColor : Color(.separator),
                                                          lineWidth: model.pageID == pageID ? 2.5 : 0.5))
        .accessibilityLabel("Page \(number)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Thumbnails, redrawn only when a page changes.
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
