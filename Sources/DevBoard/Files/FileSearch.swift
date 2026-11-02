import AppKit
import Observation

struct FileHit: Identifiable, Hashable {
    var url: URL
    var used: Date?
    var id: URL { url }
}

/// Spotlight filename search over your home folder and /Applications, most recently used first.
@MainActor @Observable
final class FileSearch {
    var text = "" { didSet { schedule() } }
    private(set) var hits: [FileHit] = []
    private(set) var searching = false

    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private static let limit = 80
    private static let skip = ["/Library/", "/node_modules/", "/.build/", "/.git/", "/DerivedData/", "/.Trash/"]

    private func schedule() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            self?.run()
        }
    }

    func stop() {
        query?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        query = nil
        searching = false
    }

    private func run() {
        stop()
        let term = text.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { hits = []; return }
        let q = NSMetadataQuery()
        // Every word must appear in the file name, in any order ("notes hpe" finds "HPE notes.docx").
        let parts = term.split(separator: " ").map { NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\($0)*") }
        q.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: parts)
        q.searchScopes = [NSMetadataQueryUserHomeScope, URL(fileURLWithPath: "/Applications")]
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false),
                             NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        q.notificationBatchingInterval = 0.2
        let nc = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(nc.addObserver(forName: name, object: q, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collect(q) }
            })
        }
        query = q
        searching = true
        q.start()
    }

    private func collect(_ q: NSMetadataQuery) {
        guard q === query else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }
        var out: [FileHit] = []
        out.reserveCapacity(Self.limit)
        for i in 0..<q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if Self.skip.contains(where: path.contains) { continue }
            if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            // Don't list the contents of app bundles.
            if let r = path.range(of: ".app/") , r.upperBound < path.endIndex { continue }
            out.append(FileHit(url: URL(fileURLWithPath: path), used: item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date))
            if out.count == Self.limit { break }
        }
        hits = out
        if q.isGathering == false { searching = false }
    }
}
