import AppKit
import SwiftUI

/// Files tab: the shelf on the left, quick search on the right.
struct FilesView: View {
    let model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var selection: URL?
    @State private var dropTargeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            shelf.frame(width: 330)
            search
        }
        .onAppear { model.shelf.prune(); searchFocused = true }
        .onChange(of: model.focusSearchToken) { _, _ in searchFocused = true }
    }

    // MARK: Shelf

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Shelf", symbol: "tray.full", trailing: model.shelf.isEmpty ? nil : "\(model.shelf.items.count)")
            if model.shelf.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 30, weight: .semibold)).foregroundStyle(.secondary)
                    Text("Drop files here or on the island").font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    Text("Switch apps, then drag them back out.\nFiles stay where they are; DevBoard only remembers them.")
                        .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                        ForEach(model.shelf.items, id: \.self) { url in
                            ShelfTile(model: model, url: url)
                        }
                    }
                }
                .scrollIndicators(.never)
                HStack {
                    Text("Drag out to use · double-click to open").font(.system(size: 10.5, design: .rounded)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Clear") { withAnimation(DB.spring) { model.shelf.clear() } }
                        .buttonStyle(.link).font(.system(size: 11, weight: .medium, design: .rounded))
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity)
        .card(radius: 22, highlighted: dropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Shelf.load(providers) { urls in withAnimation(DB.spring) { model.shelf.add(urls) } }
            return true
        }
    }

    // MARK: Search

    private var search: some View {
        @Bindable var fs = model.fileSearch
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search files by name", text: $fs.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .focused($searchFocused)
                    .onSubmit { if let u = selection ?? fs.hits.first?.url { open(u) } }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                if fs.searching { ProgressView().controlSize(.small) }
                if !fs.text.isEmpty {
                    BubbleButton(symbol: "xmark.circle.fill", help: "Clear", tint: .secondary, size: 24) { fs.text = "" }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .card(radius: 16, highlighted: searchFocused)

            if fs.text.isEmpty {
                VStack(spacing: 6) {
                    Text("Type part of a file name").font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    Text("Searches your home folder and Applications with Spotlight. ↑↓ to pick, ⏎ to open,\nHTML pages open right here in DevBoard. Drag any result out or onto the shelf.")
                        .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if fs.hits.isEmpty && !fs.searching {
                Text("Nothing called “\(fs.text)”").font(.system(size: 12.5, design: .rounded)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(fs.hits) { hit in
                                HitRow(model: model, hit: hit, selected: selection == hit.url) { open(hit.url) }
                                    .id(hit.url)
                                    .onTapGesture(count: 2) { open(hit.url) }
                                    .simultaneousGesture(TapGesture().onEnded { selection = hit.url })
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: selection) { _, s in if let s { withAnimation(DB.snappy) { proxy.scrollTo(s, anchor: .center) } } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: fs.hits) { _, hits in
            if let s = selection, hits.contains(where: { $0.url == s }) { return }
            selection = hits.first?.url
        }
    }

    private func move(_ delta: Int) {
        let hits = model.fileSearch.hits
        guard !hits.isEmpty else { return }
        let i = hits.firstIndex { $0.url == selection } ?? -1
        selection = hits[max(0, min(hits.count - 1, i + delta))].url
    }

    private func open(_ url: URL) { model.openFile(url) }
}

private struct ShelfTile: View {
    let model: AppModel
    let url: URL
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: FileKind.icon(url)).resizable().frame(width: 46, height: 46)
            Text(url.lastPathComponent)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(height: 28, alignment: .top)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(hover ? 0.1 : 0.04)))
        .overlay(alignment: .topTrailing) {
            if hover {
                BubbleButton(symbol: "xmark", help: "Remove from shelf (the file stays)", tint: .secondary, size: 20) {
                    withAnimation(DB.spring) { model.shelf.remove(url) }
                }
                .padding(2)
            }
        }
        .overlay(alignment: .topLeading) {
            if FileKind.webEntry(for: url) != nil {
                Image(systemName: "globe").font(.system(size: 9, weight: .bold)).foregroundStyle(DB.accent).padding(7)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { h in withAnimation(DB.snappy) { hover = h } }
        .onTapGesture(count: 2) { model.openFile(url) }
        .onDrag { FileKind.dragProvider(url) }
        .help(url.path)
        .contextMenu { FileMenu(model: model, url: url, onShelf: true) }
    }
}

private struct HitRow: View {
    let model: AppModel
    let hit: FileHit
    let selected: Bool
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileKind.icon(hit.url)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.url.lastPathComponent).font(.system(size: 12.5, weight: .semibold, design: .rounded)).lineLimit(1)
                Text(hit.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10.5, design: .rounded)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if let used = hit.used {
                Text(Fmt.ago(used)).font(.system(size: 10.5, design: .rounded)).foregroundStyle(.tertiary)
            }
            if hover || selected {
                if FileKind.webEntry(for: hit.url) != nil {
                    BubbleButton(symbol: "globe", help: "Open in DevBoard", tint: DB.accent, size: 24) { WebWindows.shared.openFile(hit.url) }
                }
                BubbleButton(symbol: "tray.and.arrow.down", help: "Add to shelf", size: 24) {
                    withAnimation(DB.spring) { model.shelf.add([hit.url]) }
                }
                BubbleButton(symbol: "folder", help: "Show in Finder", size: 24) {
                    NSWorkspace.shared.activateFileViewerSelecting([hit.url])
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(selected ? 0.13 : hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onDrag { FileKind.dragProvider(hit.url) }
        .contextMenu { FileMenu(model: model, url: hit.url, onShelf: false) }
    }
}

struct FileMenu: View {
    let model: AppModel
    let url: URL
    let onShelf: Bool

    var body: some View {
        if FileKind.webEntry(for: url) != nil {
            Button("Open in DevBoard", systemImage: "globe") { WebWindows.shared.openFile(url) }
        }
        Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
        Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copy path", systemImage: "doc.on.clipboard") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
        Divider()
        if onShelf {
            Button("Remove from shelf", systemImage: "minus.circle") { model.shelf.remove(url) }
        } else {
            Button("Add to shelf", systemImage: "tray.and.arrow.down") { model.shelf.add([url]) }
        }
    }
}
