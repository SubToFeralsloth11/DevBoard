import AppKit
import Observation
import UniformTypeIdentifiers

/// Files parked in DevBoard: drop them on the island, switch apps, drag them back out.
/// Items are references to the original files (nothing is copied); the list survives relaunches.
@MainActor @Observable
final class Shelf {
    private(set) var items: [URL] = []
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let key = "shelfItems"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var isEmpty: Bool { items.isEmpty }

    func add(_ urls: [URL]) {
        var changed = false
        for url in urls.map(\.standardizedFileURL) where !items.contains(url) {
            items.append(url)
            changed = true
        }
        if changed { save() }
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    /// Drops files that were deleted or moved away since they were shelved.
    func prune() {
        let alive = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        if alive.count != items.count { items = alive; save() }
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.path), forKey: key)
        onChange?()
    }

    /// Reads file URLs out of drop providers.
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let box = URLBox()
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { box.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { completion(box.urls) } }
    }
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []
    func append(_ u: URL) { lock.lock(); list.append(u); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return list }
}

enum FileKind {
    /// Pages DevBoard can show itself: HTML files, or folders with an index.html.
    static func webEntry(for url: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue {
            let index = url.appendingPathComponent("index.html")
            return FileManager.default.fileExists(atPath: index.path) ? index : nil
        }
        return ["html", "htm", "xhtml", "svg"].contains(url.pathExtension.lowercased()) ? url : nil
    }

    static func icon(_ url: URL) -> NSImage {
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 64, height: 64)
        return img
    }

    static func dragProvider(_ url: URL) -> NSItemProvider {
        NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
}

/// Notices when you start dragging files anywhere on the Mac so the island can turn into a drop zone.
/// Mouse monitors need no extra permission; only key monitors do.
@MainActor
final class FileDragWatcher {
    var onChange: ((Bool) -> Void)?
    var ignore: () -> Bool = { false }
    private var monitor: Any?
    private var lastCount = NSPasteboard(name: .drag).changeCount
    private var active = false

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragged() }
        }
    }

    private func dragged() {
        guard !active else { return }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        guard !ignore(), pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        active = true
        onChange?(true)
        Task { [weak self] in
            // The drag loop swallows mouse-up events, so poll the button state instead.
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(120)) }
            try? await Task.sleep(for: .milliseconds(250))   // let a drop on the island land first
            guard let self else { return }
            self.active = false
            self.onChange?(false)
        }
    }
}
