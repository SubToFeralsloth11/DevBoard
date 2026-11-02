import AppKit
import Observation

struct FileHit: Identifiable, Hashable {
    var rummageID: Int
    var url: URL
    var kind: String
    var match: String        // "name", "text", "meaning", "project", …
    var snippet: String
    var modified: Date
    var id: URL { url }
}

/// Searches through Rummage (~/code/rummage), the offline plain-English search app:
/// "that receipt from October", "the code where I did pathfinding", "pdfs from last week".
/// DevBoard talks to Rummage's local server and starts it in the background if it isn't running.
@MainActor @Observable
final class FileSearch {
    enum State: Equatable { case idle, starting, searching, ready, unavailable(String) }

    var text = "" { didSet { schedule() } }
    private(set) var hits: [FileHit] = []
    private(set) var total = 0
    private(set) var chips: [String] = []
    private(set) var keywordOnly = false
    private(set) var state: State = .idle

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var server: Process?
    @ObservationIgnored private var generation = 0

    static let port = 47615
    private static let base = URL(string: "http://127.0.0.1:\(port)")!

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var searching: Bool { state == .searching || state == .starting }

    func thumbnailURL(_ hit: FileHit) -> URL {
        Self.base.appending(path: "api/thumb").appending(queryItems: [.init(name: "id", value: String(hit.rummageID))])
    }

    private func schedule() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    func retry() { schedule() }

    private func run() async {
        let term = text.trimmingCharacters(in: .whitespaces)
        generation += 1
        let gen = generation
        guard !term.isEmpty else { hits = []; chips = []; total = 0; state = .idle; return }
        if !(await Self.alive()) {
            state = .starting
            if let problem = await startServer() { if gen == generation { state = .unavailable(problem) }; return }
        }
        guard gen == generation else { return }
        state = .searching
        let url = Self.base.appending(path: "api/search").appending(queryItems: [.init(name: "q", value: term), .init(name: "limit", value: "60")])
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard gen == generation else { return }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            hits = (obj["results"] as? [[String: Any]] ?? []).compactMap(Self.hit)
            total = obj["total"] as? Int ?? hits.count
            chips = (obj["chips"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            keywordOnly = (obj["semantic"] as? Bool) == false
            state = .ready
        } catch {
            guard gen == generation else { return }
            state = .unavailable("Rummage didn't answer: \(error.localizedDescription)")
        }
    }

    private static func hit(_ r: [String: Any]) -> FileHit? {
        guard let id = r["id"] as? Int, let path = r["path"] as? String else { return nil }
        return FileHit(rummageID: id, url: URL(fileURLWithPath: path), kind: r["kind"] as? String ?? "",
                       match: r["match"] as? String ?? "", snippet: (r["snippet"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                       modified: Date(timeIntervalSince1970: r["mtime"] as? Double ?? 0))
    }

    private static func alive() async -> Bool {
        var req = URLRequest(url: base.appending(path: "api/status"), timeoutInterval: 1.5)
        req.httpMethod = "HEAD"
        guard let (_, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return false }
        return (http.value(forHTTPHeaderField: "Server") ?? "").hasPrefix("Rummage")
    }

    /// Starts `uv run rummage serve` without opening a browser tab, the same way Rummage.command does.
    /// It keeps running after DevBoard quits, like when you start it yourself. Returns a problem, or nil once it answers.
    private func startServer() async -> String? {
        let dir = URL(fileURLWithPath: (settings.rummagePath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("pyproject.toml").path) else {
            return "Rummage isn't at \(settings.rummagePath). Set its folder in Settings."
        }
        let home = NSHomeDirectory()
        guard let uv = ["\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.cargo/bin/uv"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return "Rummage needs uv, which isn't installed."
        }
        if server?.isRunning != true {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: uv)
            p.arguments = ["run", "--quiet", "rummage", "serve", "--port", String(Self.port), "--no-browser"]
            p.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return "Couldn't start Rummage: \(error.localizedDescription)" }
            server = p
        }
        // First start can install dependencies; after that it answers in a few seconds.
        for _ in 0..<120 {
            if await Self.alive() { return nil }
            if server?.isRunning == false { return "Rummage stopped while starting. Try Rummage.command to see why." }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return "Rummage is taking a long time to start."
    }

    /// Opens Rummage's own page (previews, 3D viewer, filters) for the current search.
    func openInRummage() {
        let q = text.trimmingCharacters(in: .whitespaces)
        NSWorkspace.shared.open(q.isEmpty ? Self.base : Self.base.appending(queryItems: [.init(name: "q", value: q)]))
    }
}
