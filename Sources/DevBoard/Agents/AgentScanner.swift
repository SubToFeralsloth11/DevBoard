import Darwin
import Foundation
import Observation
import SwiftUI

enum FeedKind: Sendable { case user, thinking, text, tool, result, system }

struct FeedLine: Identifiable, Equatable, Sendable {
    let id: Int
    let kind: FeedKind
    let symbol: String
    let title: String
    let detail: String
    let time: Date?
    var isError = false
}

enum AgentStatus: Equatable, Sendable {
    case thinking, running, waiting, done, failed, idle

    var label: String {
        switch self {
        case .thinking: "Thinking"
        case .running: "Working"
        case .waiting: "Waiting for you"
        case .done: "Done"
        case .failed: "Stopped"
        case .idle: "Idle"
        }
    }
    var color: Color {
        switch self {
        case .thinking: DB.violet
        case .running: DB.mint
        case .waiting: DB.amber
        case .done: DB.accent
        case .failed: DB.rec
        case .idle: .gray
        }
    }
    var isWorking: Bool { self == .thinking || self == .running }
}

struct AgentSnapshot: Identifiable, Equatable, Sendable {
    let id: String                     // transcript path
    var title = ""
    var cwd = ""
    var model = ""
    var thinkingLevel = ""
    var name = ""                      // subagent name (file stem)
    var parentID: String?
    var status: AgentStatus = .idle
    var toolName: String?
    var toolIntent: String?
    var toolDetail: String?
    var lines: [FeedLine] = []
    var started: Date?
    var lastEvent: Date = .distantPast
    var cost = 0.0
    var tokens = 0
    var toolCalls = 0
    var recentEvents: [Date] = []      // last 10 minutes, for the activity strip
    var live = false
    var partial = false                // huge transcript: totals cover the tail only

    var isSubagent: Bool { parentID != nil }
    var project: String {
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty || cwd == NSHomeDirectory() ? "~" : base
    }
    var displayName: String { isSubagent ? name : project }
}

/// Watches omp transcripts (~/.omp/agent/sessions) and keeps a small live snapshot of each recent agent.
/// Transcripts are read incrementally; only the last few dozen feed lines are kept per agent.
@MainActor @Observable
final class AgentScanner {
    private(set) var agents: [String: AgentSnapshot] = [:]
    var windowMinutes = 30 { didSet { if windowMinutes != oldValue { worker.setWindow(windowMinutes) } } }

    @ObservationIgnored var onAgentFinished: ((AgentSnapshot) -> Void)?
    @ObservationIgnored private let worker = TranscriptWorker()
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var ageTimer: Timer?

    func start() {
        worker.onUpdate = { [weak self] snaps, removed, initial in
            Task { @MainActor in self?.apply(snaps, removed: removed, initial: initial) }
        }
        worker.start(windowMinutes: windowMinutes)
        ageTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.worker.tick() }
        }
    }

    private func apply(_ snaps: [AgentSnapshot], removed: [String], initial: Bool) {
        for s in snaps {
            let old = agents[s.id]
            if ready, !s.isSubagent, let old, old.status.isWorking, s.status == .waiting {
                onAgentFinished?(s)
            }
            if old != s { agents[s.id] = s }
        }
        for id in removed { agents[id] = nil }
        if initial { ready = true }
    }

    /// Top-level sessions, busiest first.
    var mains: [AgentSnapshot] {
        agents.values.filter { !$0.isSubagent }.sorted(by: Self.order)
    }

    func children(of id: String) -> [AgentSnapshot] {
        agents.values.filter { $0.parentID == id }.sorted(by: Self.order)
    }

    var workingCount: Int { agents.values.filter { $0.status.isWorking }.count }
    var waitingCount: Int { agents.values.filter { !$0.isSubagent && $0.status == .waiting }.count }

    private static func order(_ a: AgentSnapshot, _ b: AgentSnapshot) -> Bool {
        if a.status.isWorking != b.status.isWorking { return a.status.isWorking }
        if a.live != b.live { return a.live }
        return a.lastEvent > b.lastEvent
    }
}

// MARK: - Worker

private final class SessionState {
    var snap: AgentSnapshot
    var offset: UInt64 = 0
    var remainder = Data()
    var seq = 0
    init(path: String) { snap = AgentSnapshot(id: path) }
}

/// Parses transcripts on a private queue. All mutable state is confined to `queue`.
private final class TranscriptWorker: @unchecked Sendable {
    var onUpdate: (([AgentSnapshot], [String], Bool) -> Void)?

    private let queue = DispatchQueue(label: "devboard.agents", qos: .utility)
    private let root = NSHomeDirectory() + "/.omp/agent/sessions"
    private let terminals = NSHomeDirectory() + "/.omp/agent/terminal-sessions"
    private var states: [String: SessionState] = [:]
    private var watcher: FileWatcher?
    private var window: TimeInterval = 1800
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let maxLines = 80
    private static let fullReadLimit: UInt64 = 8 << 20
    private static let tailRead: UInt64 = 2 << 20

    func start(windowMinutes: Int) {
        queue.async { [self] in
            window = TimeInterval(windowMinutes * 60)
            initialScan()
            watcher = FileWatcher(path: root, queue: queue) { [weak self] paths in self?.changed(paths) }
        }
    }

    func setWindow(_ minutes: Int) {
        queue.async { [self] in
            window = TimeInterval(minutes * 60)
            initialScan()
        }
    }

    /// Periodic: live-terminal detection and dropping agents that aged out.
    func tick() {
        queue.async { [self] in
            let live = liveSessions()
            var changed: [AgentSnapshot] = []
            var removed: [String] = []
            let now = Date()
            // A parent waiting on its subagents is still busy: count their activity as its own.
            var childLatest: [String: Date] = [:]
            for st in states.values {
                if let p = st.snap.parentID { childLatest[p] = max(childLatest[p] ?? .distantPast, st.snap.lastEvent) }
            }
            for (path, st) in states {
                var s = st.snap
                let active = max(s.lastEvent, childLatest[path] ?? .distantPast)
                s.live = live.contains(path) || (s.parentID.map { live.contains($0) && s.status.isWorking } ?? false)
                if s.status.isWorking, now.timeIntervalSince(active) > 600 { s.status = .idle }
                s.recentEvents.removeAll { now.timeIntervalSince($0) > 600 }
                if !s.live, now.timeIntervalSince(active) > window {
                    states[path] = nil
                    removed.append(path)
                    continue
                }
                if s != st.snap {
                    st.snap = s
                    changed.append(s)
                }
            }
            if !changed.isEmpty || !removed.isEmpty { onUpdate?(changed, removed, false) }
        }
    }

    // MARK: Discovery

    private func initialScan() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let cutoff = Date().addingTimeInterval(-window)
        let live = liveSessions()
        var touched: [String] = []

        let projects = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys)) ?? []
        for project in projects {
            let entries = (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: keys)) ?? []
            for e in entries where e.pathExtension == "jsonl" {
                let mtime = (try? e.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                guard mtime > cutoff || live.contains(e.path) else { continue }
                touched.append(e.path)
                // Subagents live in a sibling directory named after the session.
                let dir = e.deletingPathExtension()
                let subs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
                for sub in subs where sub.pathExtension == "jsonl" {
                    let m = (try? sub.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    if m > cutoff { touched.append(sub.path) }
                }
            }
        }
        var snaps: [AgentSnapshot] = []
        for path in touched {
            if let s = ingest(path) { snaps.append(s) }
        }
        let now = Date()
        for i in snaps.indices {
            snaps[i].live = live.contains(snaps[i].id)
            if snaps[i].status.isWorking, now.timeIntervalSince(snaps[i].lastEvent) > 600 { snaps[i].status = .idle }
        }
        for s in snaps { states[s.id]?.snap = s }
        onUpdate?(snaps, [], true)
    }

    private func changed(_ paths: [String]) {
        var snaps: [String: AgentSnapshot] = [:]
        var removed: [String] = []
        for p in Set(paths) where p.hasSuffix(".jsonl") {
            if let s = ingest(p) {
                snaps[s.id] = s
            } else if states[p] == nil, !FileManager.default.fileExists(atPath: p) {
                removed.append(p)
            }
        }
        if !snaps.isEmpty || !removed.isEmpty { onUpdate?(Array(snaps.values), removed, false) }
    }

    // MARK: Reading

    private func ingest(_ path: String) -> AgentSnapshot? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            states[path] = nil
            return nil
        }
        let isNew = states[path] == nil
        let st = states[path] ?? SessionState(path: path)
        if size < st.offset {   // rewritten from scratch
            st.offset = 0
            st.remainder.removeAll()
        }
        if isNew {
            let parent = (path as NSString).deletingLastPathComponent
            if parent.hasSuffix(".jsonl") == false, FileManager.default.fileExists(atPath: parent + ".jsonl") {
                st.snap.parentID = parent + ".jsonl"
                st.snap.name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            if size > Self.fullReadLimit {
                readHead(path, into: st, includeSession: true)
                st.offset = size - Self.tailRead
                st.snap.partial = true
                st.remainder = Data([0])   // marker: drop the first (cut) line
            }
            states[path] = st
        } else {
            readHead(path, into: st)   // title line is rewritten in place
        }
        guard size > st.offset, let h = FileHandle(forReadingAtPath: path) else { return isNew ? st.snap : nil }
        defer { try? h.close() }
        try? h.seek(toOffset: st.offset)
        guard let data = try? h.read(upToCount: Int(size - st.offset)), !data.isEmpty else { return nil }
        st.offset += UInt64(data.count)

        var buffer: Data
        var dropFirst = false
        if st.remainder == Data([0]) { buffer = data; dropFirst = true } else { buffer = st.remainder + data }
        st.remainder.removeAll(keepingCapacity: false)
        var lines = buffer.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if let last = lines.last, buffer.last != UInt8(ascii: "\n") {
            st.remainder = Data(last)
            lines.removeLast()
        }
        if dropFirst, !lines.isEmpty { lines.removeFirst() }
        for line in lines where !line.isEmpty {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            apply(obj, to: st)
        }
        return st.snap
    }

    /// Line 1 is the title (rewritten in place). For tail-only reads, line 2 (`session`) carries cwd and parent.
    private func readHead(_ path: String, into st: SessionState, includeSession: Bool = false) {
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 16_384) else { return }
        for line in data.split(separator: UInt8(ascii: "\n")).prefix(4) {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "title":
                if let t = obj["title"] as? String, !t.isEmpty { st.snap.title = Self.clean(t) }
            case "session" where includeSession:
                apply(obj, to: st)
            default:
                break
            }
        }
    }

    // MARK: Parsing

    private func apply(_ obj: [String: Any], to st: SessionState) {
        let type = obj["type"] as? String ?? ""
        let ts = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) }
        if let ts, type == "message" || type == "custom" {
            if ts > st.snap.lastEvent { st.snap.lastEvent = ts }
            if Date().timeIntervalSince(ts) < 600 { st.snap.recentEvents.append(ts) }
        }
        switch type {
        case "title", "title_change":
            if let t = obj["title"] as? String, !t.isEmpty { st.snap.title = Self.clean(t) }
        case "session":
            st.snap.cwd = obj["cwd"] as? String ?? st.snap.cwd
            st.snap.started = ts
            if let p = obj["parentSession"] as? String { st.snap.parentID = p }
            if let ts, ts > st.snap.lastEvent { st.snap.lastEvent = ts }
        case "model_change":
            if let m = obj["model"] as? String { st.snap.model = Self.shortModel(m) }
        case "thinking_level_change":
            st.snap.thinkingLevel = obj["thinkingLevel"] as? String ?? ""
        case "message":
            guard let m = obj["message"] as? [String: Any] else { return }
            message(m, role: m["role"] as? String ?? "", ts: ts, st: st)
        case "custom":
            if obj["customType"] as? String == "tool_execution_start" { st.snap.status = .running }
        default:
            break
        }
    }

    private func message(_ m: [String: Any], role: String, ts: Date?, st: SessionState) {
        switch role {
        case "user":
            let text = Self.text(of: m["content"])
            if !text.isEmpty {
                add(st, .user, "person.crop.circle.fill", st.snap.isSubagent ? "Task" : "You", Self.trim(text, 360), ts)
            }
            st.snap.status = .thinking
        case "assistant":
            if let model = m["model"] as? String { st.snap.model = Self.shortModel(model) }
            if let usage = m["usage"] as? [String: Any] {
                st.snap.tokens += usage["totalTokens"] as? Int ?? 0
                st.snap.cost += (usage["cost"] as? [String: Any])?["total"] as? Double ?? 0
            }
            var usedTool = false
            for block in m["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "thinking":
                    let t = Self.squash(block["thinking"] as? String ?? "")
                    if !t.isEmpty { add(st, .thinking, "brain", "Thinking", Self.trim(t, 220), ts) }
                case "text":
                    let t = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { add(st, .text, "text.bubble.fill", "Says", Self.trim(t, 420), ts) }
                case "toolCall":
                    usedTool = true
                    let name = block["name"] as? String ?? "tool"
                    let intent = block["intent"] as? String
                    let args = block["arguments"] as? [String: Any] ?? [:]
                    let detail = Self.summary(tool: name, args: args)
                    st.snap.toolCalls += 1
                    st.snap.toolName = name
                    st.snap.toolIntent = intent
                    st.snap.toolDetail = detail
                    add(st, .tool, Self.symbol(for: name), intent ?? name, detail, ts)
                default: break
                }
            }
            let stop = m["stopReason"] as? String ?? ""
            if usedTool {
                st.snap.status = .running
            } else if stop == "error" || stop == "aborted" {
                st.snap.status = .failed
                let msg = m["errorMessage"] as? String ?? (stop == "aborted" ? "Interrupted" : "Error")
                add(st, .system, "exclamationmark.triangle.fill", "Stopped", Self.trim(msg, 240), ts, error: true)
            } else {
                st.snap.status = st.snap.isSubagent ? .done : .waiting
                st.snap.toolName = nil
                st.snap.toolIntent = nil
                st.snap.toolDetail = nil
            }
        case "toolResult":
            let isError = m["isError"] as? Bool ?? false
            let out = Self.text(of: m["content"])
            add(st, .result, isError ? "xmark.octagon.fill" : "arrow.turn.down.right", m["toolName"] as? String ?? "result",
                Self.tailLines(out), ts, error: isError)
            st.snap.status = .thinking
        default:
            break
        }
    }

    private func add(_ st: SessionState, _ kind: FeedKind, _ symbol: String, _ title: String, _ detail: String, _ ts: Date?, error: Bool = false) {
        st.seq += 1
        st.snap.lines.append(FeedLine(id: st.seq, kind: kind, symbol: symbol, title: title, detail: detail, time: ts, isError: error))
        if st.snap.lines.count > Self.maxLines { st.snap.lines.removeFirst(st.snap.lines.count - Self.maxLines) }
    }

    // MARK: Live detection

    /// Transcripts open in a terminal that currently runs an `omp` process.
    private func liveSessions() -> Set<String> {
        let ttys = ompTTYs()
        guard !ttys.isEmpty else { return [] }
        var result = Set<String>()
        for tty in ttys {
            guard let text = try? String(contentsOfFile: terminals + "/" + tty, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n")
            if lines.count >= 2 { result.insert(String(lines[1])) }
        }
        return result
    }

    private func ompTTYs() -> Set<String> {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var out = Set<String>()
        var name = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(got) where pid > 0 {
            guard proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == "omp" else { continue }
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  bsd.e_tdev != UInt32(bitPattern: -1), bsd.e_tdev != 0,
                  let dn = devname(dev_t(bitPattern: bsd.e_tdev), S_IFCHR) else { continue }
            out.insert(String(cString: dn))
        }
        return out
    }

    // MARK: Text helpers

    static func clean(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !(0xE000...0xF8FF).contains($0.value) }))
            .trimmingCharacters(in: .whitespaces)
    }

    static func shortModel(_ m: String) -> String {
        (m.split(separator: "/").last.map(String.init) ?? m)
            .replacingOccurrences(of: "claude-", with: "")
    }

    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    static func squash(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func trim(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }

    static func tailLines(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true).suffix(6)
        return lines.map { trim(String($0), 160) }.joined(separator: "\n")
    }

    static func summary(tool: String, args: [String: Any]) -> String {
        func str(_ k: String) -> String? { args[k] as? String }
        let first: String
        switch tool {
        case "bash": first = str("command") ?? ""
        case "read", "write": first = str("path") ?? ""
        case "edit": first = str("input")?.split(separator: "\n").first.map(String.init) ?? ""
        case "grep": first = [str("pattern"), str("path")].compactMap { $0 }.joined(separator: "  in  ")
        case "find": first = str("query") ?? ""
        case "glob": first = str("path") ?? ""
        case "eval": first = str("code")?.split(separator: "\n").first.map(String.init) ?? ""
        case "web_search": first = str("query") ?? ""
        case "todo": first = [str("op"), str("task")].compactMap { $0 }.joined(separator: " · ")
        case "task":
            let tasks = args["tasks"] as? [[String: Any]] ?? []
            let names = tasks.compactMap { $0["name"] as? String }
            first = names.isEmpty ? "\(tasks.count) subagent(s)" : "spawn " + names.joined(separator: ", ")
        default:
            let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
            first = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        return trim(squash(first), 220)
    }

    static func symbol(for tool: String) -> String {
        switch tool {
        case "bash": "terminal.fill"
        case "read": "doc.text.fill"
        case "edit", "ast_edit": "pencil.line"
        case "write": "square.and.pencil"
        case "grep", "find", "glob": "magnifyingglass"
        case "task": "person.2.fill"
        case "eval": "chevron.left.forwardslash.chevron.right"
        case "web_search": "globe"
        case "todo": "checklist"
        case "ask": "questionmark.bubble.fill"
        case "wait": "hourglass"
        case "browser": "safari.fill"
        case "lsp": "curlybraces"
        default: "wrench.and.screwdriver.fill"
        }
    }
}
