import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipsView: View {
    let model: AppModel
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", clips = "Clips", shots = "Screenshots"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            if let clip = model.editingClip {
                Group {
                    if clip.kind == .video {
                        ClipEditor(model: model, item: clip)
                    } else {
                        ImageViewer(model: model, item: clip)
                    }
                }
                .id(clip.id)
                .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
            } else {
                gallery.transition(.opacity)
            }
        }
        .animation(DB.spring, value: model.editingClip)
        .onAppear { model.library.reload() }
    }

    private var items: [ClipItem] {
        switch filter {
        case .all: model.library.items
        case .clips: model.library.items.filter { $0.kind == .video }
        case .shots: model.library.items.filter { $0.kind == .image }
        }
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            CaptureBar(model: model)
            HStack(spacing: 10) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Spacer()
                Text("\(model.library.items.count) items · \(ByteCountFormatter.string(fromByteCount: model.library.totalSize, countStyle: .file))")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                BubbleButton(symbol: "folder", help: "Open DevBoard folder in Finder", tint: .secondary) {
                    NSWorkspace.shared.open(model.library.root)
                }
            }
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(LinearGradient(colors: [DB.pink, DB.violet], startPoint: .top, endPoint: .bottom))
                    Text("Nothing here yet").font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("⌥⇧S screenshot  ·  ⌥⇧R record  ·  ⌥⇧X save the last \(model.settings.replaySeconds)s")
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 260), spacing: 12)], spacing: 12) {
                        ForEach(items) { item in
                            ClipTile(model: model, item: item)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
            }
        }
    }
}

/// Quick capture controls + replay buffer status.
private struct CaptureBar: View {
    let model: AppModel

    var body: some View {
        let c = model.capture
        let s = model.settings
        HStack(spacing: 10) {
            CaptureButton(symbol: "camera.viewfinder", title: "Screenshot", subtitle: "Region · ⌥⇧S", tint: DB.accent) {
                model.perform(.screenshotRegion)
            }
            CaptureButton(symbol: c.isRecording ? "stop.fill" : "record.circle",
                          title: c.isRecording ? "Stop" : "Record", subtitle: c.isRecording ? "Recording…" : "Screen · ⌥⇧R",
                          tint: DB.rec, active: c.isRecording) {
                model.perform(.toggleRecording)
            }
            CaptureButton(symbol: "memories", title: "Save replay", subtitle: c.replayArmed ? "Last \(s.replaySeconds)s · ⌥⇧X" : "Replay is off",
                          tint: DB.amber, active: false, disabled: !c.replayArmed || c.busy) {
                model.perform(.saveReplay)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    PulseDot(color: c.replayArmed ? DB.amber : .gray, active: c.replayArmed, size: 6).frame(width: 12, height: 12)
                    Text(c.replayArmed ? "Instant replay on" : replayStateText(c.streamState))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                Text("\(s.quality.label)\(s.fps) · \(s.systemAudio ? "system audio" : "no audio")\(s.microphone ? " + mic" : "") · buffered on disk")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Toggle("", isOn: Binding(get: { s.replayEnabled }, set: { _ in model.perform(.toggleReplay) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
        }
        .padding(12)
        .card(radius: 22)
    }

    private func replayStateText(_ st: CaptureEngine.StreamState) -> String {
        switch st {
        case .starting: "Starting…"
        case .failed: "Replay unavailable"
        default: "Instant replay off"
        }
    }
}

private struct CaptureButton: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color
    var active = false
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(tint.gradient))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(active ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.16))))
                    .symbolEffect(.pulse, isActive: active)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(subtitle).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(hover ? 0.1 : 0.04)))
            .contentShape(Capsule())
            .scaleEffect(hover ? 1.03 : 1)
        }
        .buttonStyle(PressScale())
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { h in withAnimation(DB.snappy) { hover = h } }
    }
}

private struct ClipTile: View {
    let model: AppModel
    let item: ClipItem
    @State private var thumb: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    Rectangle().fill(.white.opacity(0.05))
                    ProgressView().controlSize(.small)
                }
                if item.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: .circle)
                        .opacity(hover ? 1 : 0)
                        .scaleEffect(hover ? 1 : 0.7)
                }
            }
            .frame(height: 128)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if item.kind == .video, let d = model.library.duration(item) {
                    Text(Fmt.clock(d))
                        .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(7)
                }
            }
            .overlay(alignment: .topLeading) {
                Image(systemName: item.kind == .video ? "video.fill" : "photo.fill")
                    .font(.system(size: 9, weight: .bold))
                    .padding(6)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .padding(7)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 11.5, weight: .semibold, design: .rounded)).lineLimit(1)
                Text("\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))")
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .card(radius: 22, highlighted: hover)
        .scaleEffect(hover ? 1.025 : 1)
        .shadow(color: .black.opacity(hover ? 0.3 : 0), radius: 12, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onTapGesture { withAnimation(DB.spring) { model.editingClip = item } }
        .onHover { h in withAnimation(DB.snappy) { hover = h } }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(item.url) }
            Button("Copy", systemImage: "doc.on.doc") { ClipLibrary.copyToPasteboard(item.url) }
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive) { withAnimation(DB.spring) { model.library.trash(item) } }
        }
        .task(id: item.url) {
            if let t = model.library.cachedThumbnail(item) { thumb = t; return }
            let t = await model.library.thumbnail(item)
            withAnimation(DB.soft) { thumb = t }
        }
    }
}

// MARK: Image viewer

private struct ImageViewer: View {
    let model: AppModel
    let item: ClipItem
    @State private var image: NSImage?

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                EditorHeader(model: model, item: item)
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.black.opacity(0.35))
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(10)
                            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                    } else {
                        ProgressView()
                    }
                }
            }
            VStack(spacing: 6) {
                ActionRow(symbol: "doc.on.doc", title: "Copy image") {
                    ClipLibrary.copyToPasteboard(item.url)
                    model.showToast(Toast(symbol: "doc.on.doc.fill", title: "Copied", tint: DB.accent), seconds: 1.5)
                }
                ActionRow(symbol: "pencil.tip.crop.circle", title: "Mark up in Preview") {
                    if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
                        NSWorkspace.shared.open([item.url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                ShareRow(url: item.url)
                ActionRow(symbol: "folder", title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                ActionRow(symbol: "trash", title: "Move to Trash") {
                    model.library.trash(item)
                    withAnimation(DB.spring) { model.editingClip = nil }
                }
                Spacer()
            }
            .frame(width: 250)
            .padding(.top, 46)
        }
        .task(id: item.url) {
            let url = item.url
            let loaded = await Task.detached { NSImage(contentsOf: url) }.value
            withAnimation(DB.soft) { image = loaded }
        }
    }
}

struct EditorHeader: View {
    let model: AppModel
    let item: ClipItem
    var body: some View {
        HStack(spacing: 10) {
            BubbleButton(symbol: "chevron.left", help: "Back (Esc)", size: 32) {
                withAnimation(DB.spring) { model.editingClip = nil }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 15, weight: .bold, design: .rounded)).lineLimit(1)
                Text("\(item.date.formatted(date: .abbreviated, time: .standard)) · \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// Opens the system share menu anchored to this row.
struct ShareRow: View {
    let url: URL
    var body: some View {
        ActionRow(symbol: "square.and.arrow.up", title: "Share…") {
            guard let view = NSApp.keyWindow?.contentView else { return }
            let picker = NSSharingServicePicker(items: [url])
            let mouse = view.window?.mouseLocationOutsideOfEventStream ?? .zero
            picker.show(relativeTo: NSRect(origin: view.convert(mouse, from: nil), size: CGSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
        }
    }
}
