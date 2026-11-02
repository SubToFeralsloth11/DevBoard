import AppKit
import Observation
import SwiftUI
import WebKit

struct SchoolLesson: Identifiable, Codable, Hashable {
    var id: String
    var kind: String          // "Lesson", or another DayMap diary type (event, excursion…)
    var title: String
    var notice: String
    var start: Date
    var end: Date
}

struct SchoolTask: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var subject: String
    var kind: String
    var posted: Date?
    var due: Date             // midnight at the start of the due day
    var status: String
    var submitted: Bool
    var graded: Bool
}

enum DayMapStatus: Equatable {
    case idle, syncing, signedOut, ok, failed(String)
}

/// Pulls your timetable and tasks out of DayMap and turns them into island reminders.
///
/// DayMap has no public API and signs in through Microsoft, so DevBoard uses a real web view: you sign
/// in once in a DevBoard window, then a hidden web view with the same cookies loads your task list and
/// asks DayMap's own diary endpoint (the one its timetable page uses) for your lessons.
@MainActor @Observable
final class DayMapService {
    private(set) var lessons: [SchoolLesson] = []
    private(set) var tasks: [SchoolTask] = []
    private(set) var status: DayMapStatus = .idle
    private(set) var lastSync: Date?
    private(set) var lastProblem: String?
    /// Ticks every 30 s so countdowns and "next class" stay current.
    private(set) var now = Date()

    @ObservationIgnored var onToast: ((Toast) -> Void)?
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var signInWindow: WebWindowController?
    @ObservationIgnored private var restoredCookies = false
    @ObservationIgnored private var fired: Set<String>
    @ObservationIgnored private var knownTaskIDs: Set<String>

    private static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DevBoard", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static let cacheURL = dir.appendingPathComponent("daymap.json")
    private static let cookieURL = dir.appendingPathComponent("daymap-session.plist")

    init(settings: SettingsStore) {
        self.settings = settings
        let d = UserDefaults.standard
        fired = Set(d.stringArray(forKey: "daymapFired") ?? [])
        knownTaskIDs = Set(d.stringArray(forKey: "daymapKnownTasks") ?? [])
        loadCache()
    }

    // MARK: URLs

    var base: URL? {
        var s = settings.daymapURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s), let host = u.host() else { return nil }
        return URL(string: "https://\(host)")
    }

    func taskURL(_ t: SchoolTask) -> URL? { base?.appending(path: "daymap/student/assignment.aspx").appending(queryItems: [.init(name: "TaskID", value: t.id)]) }
    var timetableURL: URL? { base?.appending(path: "daymap/timetable/timetable.aspx") }
    private var tasksURL: URL? { base?.appending(path: "daymap/student/assignments.aspx").appending(queryItems: [.init(name: "View", value: "0")]) }

    private func isDayMapApp(_ url: URL?) -> Bool {
        guard let url, let host = base?.host() else { return false }
        return url.host()?.lowercased() == host.lowercased() && !url.path.lowercased().contains("login")
    }

    // MARK: Lifecycle

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 5
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.now = .now
                self?.syncSoon(after: 6)
            }
        }
        syncSoon(after: 4)
    }

    private func tick() {
        now = .now
        evaluateReminders()
        // Every 20 min while signed in; once an hour while signed out (Microsoft may sign us back in silently).
        let interval: TimeInterval = status == .signedOut ? 3600 : 1200
        if status != .syncing, now.timeIntervalSince(lastSync ?? .distantPast) > interval { syncNow() }
    }

    private func syncSoon(after seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.syncNow()
        }
    }

    func syncNow() {
        guard status != .syncing, base != nil else { return }
        syncTask = Task { await self.sync() }
    }

    /// Opens DayMap in a DevBoard window. As soon as it lands on a signed-in DayMap page, DevBoard syncs.
    func signIn() {
        guard let start = timetableURL else { return }
        if let w = signInWindow?.window, w.isVisible { w.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        var synced = false
        signInWindow = WebWindows.shared.openPage(start) { [weak self] url in
            guard let self, !synced, self.isDayMapApp(url) else { return }
            synced = true
            self.syncNow()
        }
    }

    func openInDevBoard(_ url: URL?) {
        guard let url else { return }
        WebWindows.shared.openPage(url)
    }

    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let mine = records.filter { r in ["daymap", "microsoftonline", "microsoft.com", "live.com"].contains { r.displayName.contains($0) } }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: mine)
        try? FileManager.default.removeItem(at: Self.cookieURL)
        lessons = []
        tasks = []
        knownTaskIDs = []
        lastSync = nil
        try? FileManager.default.removeItem(at: Self.cacheURL)
        UserDefaults.standard.removeObject(forKey: "daymapKnownTasks")
        status = .signedOut
    }

    // MARK: Sync

    private func sync() async {
        guard let tasksURL else { return }
        status = .syncing
        if !restoredCookies { await restoreSessionCookies(); restoredCookies = true }

        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: {
            let c = WKWebViewConfiguration()
            c.websiteDataStore = .default()
            return c
        }())
        defer { web.stopLoading() }

        guard await open(tasksURL, in: web) else {
            lastSync = .now
            status = .signedOut
            if !fired.contains("connect-prompt") {
                remember("connect-prompt")
                onToast?(Toast(symbol: "graduationcap.fill", title: "Connect DayMap", subtitle: "Sign in once and your tasks and classes sync here",
                               tint: DB.violet, action: .openSchool))
            }
            return
        }

        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: .now))!
        let to = cal.date(byAdding: .day, value: 21, to: from)!
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"

        let raw: Any?
        do {
            raw = try await web.callAsyncJavaScript(Self.extractJS, arguments: ["from": df.string(from: from), "to": df.string(from: to)],
                                                    in: nil, contentWorld: .page)
        } catch {
            fail("DayMap's page changed: \(error.localizedDescription)")
            return
        }
        guard let json = raw as? String, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fail("DayMap sent something DevBoard couldn't read")
            return
        }

        var problems = (obj["errors"] as? [String]) ?? []
        var newTasks = (obj["tasks"] as? [[String: Any]] ?? []).compactMap(Self.parseTask)
        var newLessons: [SchoolLesson] = []
        if let diary = obj["diary"] as? [[String: Any]] {
            for item in diary {
                if let task = Self.diaryTask(item), !newTasks.contains(where: { $0.id == task.id }) { newTasks.append(task); continue }
                if let l = Self.parseLesson(item) { newLessons.append(l) }
            }
        } else {
            problems.append("timetable unavailable")
        }

        if newTasks.isEmpty && newLessons.isEmpty && !problems.isEmpty {
            fail(problems.joined(separator: "; "))
            return
        }

        announceNewTasks(newTasks)
        tasks = newTasks.sorted { $0.due < $1.due }
        lessons = newLessons.sorted { $0.start < $1.start }
        lastSync = .now
        lastProblem = problems.isEmpty ? nil : problems.joined(separator: "; ")
        status = .ok
        saveCache()
        await saveSessionCookies()
        evaluateReminders()
    }

    private func fail(_ message: String) {
        lastSync = .now
        lastProblem = message
        status = .failed(message)
    }

    /// Loads `url` and follows DayMap's sign-in hops. True once a signed-in DayMap page has finished loading.
    private func open(_ url: URL, in web: WKWebView) async -> Bool {
        web.load(URLRequest(url: url))
        var idleOnLogin: Date?
        var clickedMicrosoft = false
        let deadline = Date.now.addingTimeInterval(45)
        while Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            if web.isLoading { idleOnLogin = nil; continue }
            if isDayMapApp(web.url) {
                let ready = (try? await web.evaluateJavaScript("document.readyState")) as? String
                if ready == "complete" { return true }
                continue
            }
            // Parked on the DayMap or Microsoft sign-in page.
            if idleOnLogin == nil { idleOnLogin = .now; continue }
            guard Date.now.timeIntervalSince(idleOnLogin!) > 2.5 else { continue }
            if !clickedMicrosoft {
                // If Microsoft still remembers you, its button signs you straight back in.
                clickedMicrosoft = true
                idleOnLogin = nil
                _ = try? await web.evaluateJavaScript(Self.microsoftButtonJS)
                continue
            }
            return false
        }
        return false
    }

    // MARK: Session cookies

    /// DayMap's app session cookie dies when DevBoard quits; keeping it means fewer sign-ins.
    private func saveSessionCookies() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let keep = cookies.filter { $0.isSessionOnly && $0.domain.contains("daymap.net") }
        let plist = keep.compactMap { c -> [String: Any]? in
            guard let p = c.properties else { return nil }
            return Dictionary(uniqueKeysWithValues: p.map { ($0.key.rawValue, $0.value) })
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else { return }
        FileManager.default.createFile(atPath: Self.cookieURL.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    private func restoreSessionCookies() async {
        guard let data = try? Data(contentsOf: Self.cookieURL),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for dict in list {
            let props = Dictionary(uniqueKeysWithValues: dict.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            if let c = HTTPCookie(properties: props) { await store.setCookie(c) }
        }
    }

    // MARK: Reminders

    private func remember(_ key: String) {
        fired.insert(key)
        if fired.count > 600 { fired = Set(fired.suffix(300)) }
        UserDefaults.standard.set(Array(fired), forKey: "daymapFired")
    }

    private func announceNewTasks(_ incoming: [SchoolTask]) {
        let ids = Set(incoming.map(\.id))
        let firstSync = knownTaskIDs.isEmpty
        let fresh = incoming.filter { !knownTaskIDs.contains($0.id) && !$0.submitted }
        knownTaskIDs.formUnion(ids)
        UserDefaults.standard.set(Array(knownTaskIDs), forKey: "daymapKnownTasks")
        guard !firstSync, settings.schoolReminders, !fresh.isEmpty else { return }
        let t = fresh[0]
        onToast?(Toast(symbol: "tray.and.arrow.down.fill",
                       title: fresh.count == 1 ? "New task: \(t.name)" : "\(fresh.count) new DayMap tasks",
                       subtitle: fresh.count == 1 ? "\(t.subject) · due \(Self.dueText(t.due, now: now))" : fresh.prefix(3).map(\.name).joined(separator: ", "),
                       tint: DB.violet, action: fresh.count == 1 ? .openSchoolTask(t.id) : .openSchool))
    }

    /// Fires each reminder once: tasks the afternoon before and the morning they're due,
    /// lessons five minutes before they start.
    private func evaluateReminders() {
        guard settings.schoolReminders else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let hour = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        var due: [(key: String, task: SchoolTask, today: Bool)] = []
        for t in tasks where !t.submitted {
            let day = cal.startOfDay(for: t.due)
            if day == today, hour >= 7 * 60 + 30, !fired.contains("today:\(t.id)") {
                due.append(("today:\(t.id)", t, true))
            } else if cal.date(byAdding: .day, value: -1, to: day) == today, hour >= 15 * 60 + 30, !fired.contains("tmrw:\(t.id)") {
                due.append(("tmrw:\(t.id)", t, false))
            }
        }
        if !due.isEmpty {
            due.forEach { remember($0.key) }
            let first = due[0]
            let toast: Toast = due.count == 1
                ? Toast(symbol: "checklist", title: "\(first.task.name) is due \(first.today ? "today" : "tomorrow")",
                        subtitle: first.task.subject, tint: first.today ? DB.rec : DB.amber, action: .openSchoolTask(first.task.id))
                : Toast(symbol: "checklist", title: "\(due.count) tasks due \(due.allSatisfy(\.today) ? "today" : "soon")",
                        subtitle: due.prefix(3).map(\.task.name).joined(separator: ", "), tint: DB.amber, action: .openSchool)
            onToast?(toast)
            return
        }
        guard settings.lessonReminders else { return }
        for l in lessons where l.kind == "Lesson" {
            let lead = l.start.timeIntervalSince(now)
            guard lead > 0, lead <= 5 * 60 + 15 else { continue }
            let key = "lesson:\(l.id):\(Int(l.start.timeIntervalSince1970))"
            guard !fired.contains(key) else { continue }
            remember(key)
            onToast?(Toast(symbol: "bell.fill", title: "\(l.title) in \(max(1, Int((lead / 60).rounded()))) min",
                           subtitle: l.notice.isEmpty ? Self.time(l.start) + " – " + Self.time(l.end) : l.notice,
                           tint: DB.accent, action: .openSchool))
            return
        }
    }

    // MARK: Island headline

    struct Headline: Equatable {
        var symbol: String
        var text: String
        var tint: Color
    }

    /// What the compact island shows: the class you're in, the next class, or the nearest task due.
    var headline: Headline? {
        let now = self.now
        let cal = Calendar.current
        let classes = lessons.filter { $0.kind == "Lesson" }
        if let current = classes.first(where: { $0.start <= now && now < $0.end }) {
            return Headline(symbol: "book.fill", text: "\(current.title) · till \(Self.time(current.end))", tint: DB.accent)
        }
        if let next = classes.first(where: { $0.start > now && $0.start.timeIntervalSince(now) < 90 * 60 }) {
            return Headline(symbol: "clock.fill", text: "\(next.title) \(Self.time(next.start))", tint: DB.accent)
        }
        let soon = tasks.filter { !$0.submitted }
            .filter { let d = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: $0.due).day ?? 99; return d >= 0 && d <= 2 }
        if let t = soon.first {
            let today = cal.isDate(t.due, inSameDayAs: now)
            return Headline(symbol: "checklist", text: "\(t.name) · \(Self.dueText(t.due, now: now))", tint: today ? DB.rec : DB.amber)
        }
        return nil
    }

    // MARK: Formatting

    static func time(_ d: Date) -> String {
        d.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute())
    }

    static func dueText(_ due: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: due)).day ?? 0
        switch days {
        case ..<(-1): return "overdue \(-days)d"
        case -1: return "was due yesterday"
        case 0: return "due today"
        case 1: return "due tmrw"
        case 2...6: return "due " + due.formatted(.dateTime.weekday(.wide))
        default: return "due " + due.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    // MARK: Parsing

    private static func value(_ d: [String: Any], _ key: String) -> Any? {
        d.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    private static func string(_ d: [String: Any], _ key: String) -> String {
        switch value(d, key) {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: ""
        }
    }

    /// DayMap writes dates as "2025-02-03T08:50:00.0000000" (local) or "/Date(1738536600000+1000)/".
    static func parseDate(_ s: String) -> Date? {
        if let open = s.range(of: "Date(") {
            let rest = s[open.upperBound...]
            let negative = rest.hasPrefix("-")
            if let ms = Double((negative ? rest.dropFirst() : rest).prefix(while: \.isNumber)) {
                return Date(timeIntervalSince1970: (negative ? -ms : ms) / 1000)
            }
        }
        let trimmed = s.split(separator: ".").first.map(String.init) ?? s
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }

    /// Australian short dates from the task list: 3/02/25 or 3/02/2025.
    static func parseShortDate(_ s: String) -> Date? {
        let parts = s.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.day = parts[0]
        c.month = parts[1]
        c.year = parts[2] < 100 ? 2000 + parts[2] : parts[2]
        return Calendar.current.date(from: c)
    }

    private static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func parseLesson(_ d: [String: Any]) -> SchoolLesson? {
        guard let start = parseDate(string(d, "Start")) else { return nil }
        let end = parseDate(string(d, "Finish")) ?? parseDate(string(d, "End")) ?? start.addingTimeInterval(3600)
        let title = stripHTML(string(d, "Title"))
        guard !title.isEmpty else { return nil }
        let kind = string(d, "Type").isEmpty ? "Lesson" : string(d, "Type")
        let id = string(d, "ID").isEmpty ? "\(title)@\(Int(start.timeIntervalSince1970))" : string(d, "ID")
        // DayMap appends hidden markup after the notice (room-change icons, detail divs).
        let text = string(d, "Text")
        let notice = text.hasPrefix("<div") ? "" : String(text[..<(text.range(of: "<div")?.lowerBound ?? text.endIndex)])
        return SchoolLesson(id: id, kind: kind, title: title, notice: stripHTML(notice), start: start, end: end)
    }

    /// Diary entries for assessment due dates, used when they aren't already in the task list.
    static func diaryTask(_ d: [String: Any]) -> SchoolTask? {
        let type = string(d, "Type").lowercased()
        guard type.contains("assign") || type.contains("task") || type.contains("assess") || type.contains("due") else { return nil }
        guard let due = parseDate(string(d, "Start")) else { return nil }
        let title = stripHTML(string(d, "Title"))
        return SchoolTask(id: "diary-\(string(d, "ID").isEmpty ? title : string(d, "ID"))", name: title, subject: "", kind: string(d, "Type"),
                          posted: nil, due: Calendar.current.startOfDay(for: due), status: "", submitted: false, graded: false)
    }

    /// One row of DayMap's task grid: [link] Class | Type | Task | Set | Due | status…
    static func parseTask(_ row: [String: Any]) -> SchoolTask? {
        guard let id = row["id"] as? String, let cells = row["cells"] as? [String] else { return nil }
        let dateIdx = cells.indices.filter { parseShortDate(cells[$0]) != nil }
        guard let first = dateIdx.first else { return nil }
        let dueIdx = dateIdx.count > 1 ? dateIdx[1] : first
        let link = (row["link"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let name = !link.isEmpty ? link : (first > 0 ? cells[first - 1] : "Task")
        let before = cells[..<first].filter { !$0.isEmpty && $0 != name }
        let after = cells[(dueIdx + 1)...].filter { !$0.isEmpty }
        let text = (row["text"] as? String ?? "").lowercased()
        let graded = text.contains("results have been published")
        let submitted = graded || text.contains("work has been received") || (text.contains("submitted") && !text.contains("not submitted"))
        return SchoolTask(id: id, name: name, subject: before.first ?? "", kind: before.count > 1 ? before[1] : "",
                          posted: dateIdx.count > 1 ? parseShortDate(cells[first]) : nil,
                          due: parseShortDate(cells[dueIdx])!, status: after.joined(separator: " · "),
                          submitted: submitted, graded: graded)
    }

    // MARK: Cache

    private struct Cache: Codable {
        var lessons: [SchoolLesson]
        var tasks: [SchoolTask]
        var synced: Date
    }

    private func saveCache() {
        guard let lastSync, let data = try? JSONEncoder().encode(Cache(lessons: lessons, tasks: tasks, synced: lastSync)) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        lessons = c.lessons
        tasks = c.tasks
        lastSync = c.synced
        status = .ok
    }

    // MARK: Page scripts

    /// Runs inside the signed-in task page. Asks the grid for every task (one page of up to 500),
    /// then fetches the diary DayMap's timetable uses. Returns JSON text.
    private static let extractJS = #"""
    const out = { tasks: [], diary: null, errors: [] };
    const clean = s => (s || '').replace(/\s+/g, ' ').trim();
    const rows = doc => {
      const list = [];
      for (const a of doc.querySelectorAll('a[href*="ViewAssignment("]')) {
        const m = (a.getAttribute('href') || '').match(/ViewAssignment\((\d+)/);
        const tr = a.closest('tr');
        if (!m || !tr) continue;
        list.push({ id: m[1], link: clean(a.textContent), cells: [...tr.cells].map(td => clean(td.textContent)), text: clean(tr.textContent) });
      }
      return list;
    };
    out.tasks = rows(document);
    try {
      const grid = document.querySelector('[id$="grdAssignments"]');
      const form = document.forms[0];
      if (grid && form) {
        const name = grid.id.replace(/_/g, '$');
        const body = new URLSearchParams(new FormData(form));
        body.set('__EVENTTARGET', name);
        body.set('__EVENTARGUMENT', 'FireCommand:' + name + '$ctl00;PageSize;500');
        for (const el of form.querySelectorAll('input')) {
          if (!el.name) continue;
          if (el.name.endsWith('PageSizeComboBox')) body.set(el.name, '500');
          if (el.name.endsWith('PageSizeComboBox_ClientState'))
            body.set(el.name, JSON.stringify({ logEntries: [], value: '500', text: '500', enabled: true, checkedIndices: [], checkedItemsTextOverflows: false }));
        }
        const r = await fetch(location.href, { method: 'POST', body, credentials: 'include',
                                               headers: { 'Content-Type': 'application/x-www-form-urlencoded' } });
        const all = rows(new DOMParser().parseFromString(await r.text(), 'text/html'));
        if (all.length > out.tasks.length) out.tasks = all;
      }
    } catch (e) { out.errors.push('task list: ' + e); }
    try {
      const r = await fetch('/daymap/DWS/Diary.ashx?cmd=EventList&from=' + from + '&to=' + to, { credentials: 'include' });
      const body = await r.text();
      const data = JSON.parse(body);
      out.diary = Array.isArray(data) ? data : (data.d || data.Events || data.events || []);
    } catch (e) { out.errors.push('timetable: ' + e); }
    return JSON.stringify(out);
    """#

    /// Clicks the "sign in with Microsoft / Office 365 / EQ" button on DayMap's sign-in page, if there is one.
    private static let microsoftButtonJS = #"""
    (() => {
      const want = /microsoft|office|365|education queensland|\beq\b|school account|sign in with/i;
      const els = [...document.querySelectorAll('a, button, [role=button], input[type=button], input[type=submit]')];
      const hit = els.find(e => (e.href || '').includes('login.microsoftonline'))
               || els.find(e => e.id !== 'btnLogIn' && want.test((e.textContent || e.value || e.title || e.getAttribute('aria-label') || '')));
      if (hit) { hit.click(); return true; }
      return false;
    })()
    """#
}
