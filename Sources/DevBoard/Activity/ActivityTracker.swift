import AppKit
import CoreLocation
import Observation

struct AppTime: Codable, Hashable {
    var name: String
    var seconds: Double
}

struct TrackPoint: Codable, Hashable {
    var lat: Double
    var lon: Double
    var t: Date
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

/// One day of activity, saved as `activity/yyyy-MM-dd.json`.
struct DayActivity: Codable {
    var day: String
    /// Physical key presses by key name (auto-repeat is not counted).
    var keys: [String: Int] = [:]
    /// ⌘/⌃ shortcuts, e.g. "⌘C".
    var shortcuts: [String: Int] = [:]
    /// Mouse and trackpad clicks by button.
    var clicks: [String: Int] = [:]
    /// Screen time per app, keyed by bundle identifier (or name when there is none).
    var apps: [String: AppTime] = [:]
    var hourlySeconds = [Double](repeating: 0, count: 24)
    var hourlyKeys = [Int](repeating: 0, count: 24)
    var points: [TrackPoint] = []

    var totalKeys: Int { keys.values.reduce(0, +) }
    var totalClicks: Int { clicks.values.reduce(0, +) }
    var screenSeconds: Double { apps.values.reduce(0) { $0 + $1.seconds } }
    var distanceMeters: Double {
        zip(points, points.dropFirst()).reduce(0) { sum, pair in
            sum + CLLocation(latitude: pair.0.lat, longitude: pair.0.lon).distance(from: CLLocation(latitude: pair.1.lat, longitude: pair.1.lon))
        }
    }
}

/// Counts key presses and clicks, adds up screen time per app, and records where the Mac travels.
/// Only counts are stored (never what you typed, never the order of keys).
@MainActor @Observable
final class ActivityTracker: NSObject, CLLocationManagerDelegate {
    /// Today's numbers, published every tick (2 s) so the board doesn't redraw on every key press.
    private(set) var today: DayActivity
    private(set) var keyboardAllowed = CGPreflightListenEventAccess()
    private(set) var locationStatus: CLAuthorizationStatus = .notDetermined

    @ObservationIgnored private var live: DayActivity
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastSave = Date.now
    @ObservationIgnored private var lastTick = Date.now
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var keyTap: CFMachPort?
    @ObservationIgnored private var mouseTap: CFMachPort?
    @ObservationIgnored private var locked = false
    @ObservationIgnored private var displaysAsleep = false
    @ObservationIgnored private let location = CLLocationManager()

    /// No input for this long and the time stops counting (you've walked away).
    static let idleLimit: TimeInterval = 300
    private static let tick: TimeInterval = 2

    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevBoard/activity", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for date: Date) -> String { dayFormat.string(from: date) }
    static func date(for key: String) -> Date? { dayFormat.date(from: key) }

    override init() {
        let key = Self.key(for: .now)
        let day = Self.load(key) ?? DayActivity(day: key)
        live = day
        today = day
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        installMouseTap()
        if keyboardAllowed { installKeyTap() }

        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickNow() }
        }
        timer?.tolerance = 0.5

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickNow(); self?.locked = true }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked = false; self?.lastTick = .now }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.willSleepNotification, true),
                               (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.didWakeNotification, false)] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if asleep { self.tickNow(); self.displaysAsleep = true; self.save() } else { self.displaysAsleep = false; self.lastTick = .now }
                }
            }
        }

        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyHundredMeters
        location.distanceFilter = 30
        locationStatus = location.authorizationStatus
        if locationStatus == .authorized || locationStatus == .authorizedAlways { location.startUpdatingLocation() }
    }

    func save() {
        guard dirty, let data = try? JSONEncoder().encode(live) else { return }
        try? data.write(to: Self.dir.appendingPathComponent("\(live.day).json"), options: .atomic)
        dirty = false
        lastSave = .now
    }

    // MARK: Permissions

    /// Shows the Input Monitoring prompt (or opens its settings pane if it was already declined).
    func requestKeyboard() {
        if !CGRequestListenEventAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }

    func requestLocation() {
        switch location.authorizationStatus {
        case .notDetermined:
            NSApp.activate()
            location.requestWhenInUseAuthorization()
        case .denied, .restricted:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
        default:
            location.startUpdatingLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            locationStatus = status
            if status == .authorized || status == .authorizedAlways { location.startUpdatingLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map { (lat: $0.coordinate.latitude, lon: $0.coordinate.longitude, acc: $0.horizontalAccuracy, t: $0.timestamp) }
        MainActor.assumeIsolated {
            for f in fixes { record(f.lat, f.lon, accuracy: f.acc, at: f.t) }
        }
    }

    /// Keeps a point when it is accurate enough and clearly away from the last one, so Wi-Fi jitter
    /// while sitting still doesn't draw a scribble.
    private func record(_ lat: Double, _ lon: Double, accuracy: Double, at t: Date) {
        guard accuracy > 0, accuracy <= 250, Self.key(for: t) == live.day else { return }
        if let last = live.points.last {
            let moved = CLLocation(latitude: last.lat, longitude: last.lon).distance(from: CLLocation(latitude: lat, longitude: lon))
            guard moved >= max(40, accuracy) else { return }
        }
        live.points.append(TrackPoint(lat: lat, lon: lon, t: t))
        dirty = true
    }

    // MARK: Screen time

    private func tickNow() {
        let now = Date.now
        rollOverIfNeeded(now)
        let elapsed = min(now.timeIntervalSince(lastTick), Self.tick * 4)
        lastTick = now

        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if elapsed > 0, !locked, !displaysAsleep, idle < Self.idleLimit,
           let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != "com.apple.loginwindow" {
            let id = app.bundleIdentifier ?? app.localizedName ?? "Unknown"
            live.apps[id, default: AppTime(name: app.localizedName ?? id, seconds: 0)].seconds += elapsed
            live.hourlySeconds[Calendar.current.component(.hour, from: now)] += elapsed
            dirty = true
        }

        if !keyboardAllowed, CGPreflightListenEventAccess() {
            keyboardAllowed = true
            installKeyTap()
        }
        today = live
        if now.timeIntervalSince(lastSave) > 60 { save() }
    }

    private func rollOverIfNeeded(_ now: Date) {
        let key = Self.key(for: now)
        guard key != live.day else { return }
        save()
        live = DayActivity(day: key)
        dirty = true
    }

    // MARK: Keys & clicks

    private func installMouseTap() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)
        mouseTap = makeTap(mask: CGEventMask(mask))
    }

    private func installKeyTap() {
        guard keyTap == nil else { return }
        keyTap = makeTap(mask: CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)))
    }

    /// Listen-only taps on the main run loop: they observe events and can never block or change them.
    private func makeTap(mask: CGEventMask) -> CFMachPort? {
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<ActivityTracker>.fromOpaque(refcon).takeUnretainedValue()
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            let flags = event.flags
            MainActor.assumeIsolated { me.handle(type, code: code, repeated: repeated, button: button, flags: flags) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return tap
    }

    private func handle(_ type: CGEventType, code: Int, repeated: Bool, button: Int, flags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            for tap in [keyTap, mouseTap].compactMap({ $0 }) { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            guard !repeated else { return }
            let name = KeyNames.name(code)
            countKey(name)
            if flags.contains(.maskCommand) || flags.contains(.maskControl) {
                live.shortcuts[KeyNames.modifierPrefix(flags) + name, default: 0] += 1
            }
        case .flagsChanged:
            // Fires on press and release; it's a press when that modifier's flag is now set.
            guard let (name, flag) = KeyNames.modifiers[code], flag.isEmpty || flags.contains(flag) else { return }
            countKey(name)
        case .leftMouseDown: countClick("Left click")
        case .rightMouseDown: countClick("Right click")
        case .otherMouseDown: countClick(button == 2 ? "Middle click" : "Button \(button + 1)")
        default: break
        }
    }

    private func countKey(_ name: String) {
        rollOverIfNeeded(.now)
        live.keys[name, default: 0] += 1
        live.hourlyKeys[Calendar.current.component(.hour, from: .now)] += 1
        dirty = true
    }

    private func countClick(_ name: String) {
        rollOverIfNeeded(.now)
        live.clicks[name, default: 0] += 1
        dirty = true
    }

    // MARK: History

    /// Days with saved activity, newest first (today always included).
    func savedDays() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.dir.path)) ?? []
        let days = Set(files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }).union([live.day])
        return days.sorted(by: >)
    }

    func activity(for day: String) -> DayActivity {
        day == live.day ? today : (Self.load(day) ?? DayActivity(day: day))
    }

    private static func load(_ day: String) -> DayActivity? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(day).json")) else { return nil }
        return try? JSONDecoder().decode(DayActivity.self, from: data)
    }
}

/// Names for macOS virtual key codes (physical keys, US/AU layout).
enum KeyNames {
    static func name(_ code: Int) -> String { table[code] ?? "Key \(code)" }

    static func modifierPrefix(_ f: CGEventFlags) -> String {
        (f.contains(.maskControl) ? "⌃" : "") + (f.contains(.maskAlternate) ? "⌥" : "")
            + (f.contains(.maskShift) ? "⇧" : "") + (f.contains(.maskCommand) ? "⌘" : "")
    }

    /// Modifier key code → (name, flag that is set while it is down). Caps Lock toggles, so every change counts.
    static let modifiers: [Int: (String, CGEventFlags)] = [
        55: ("⌘ Command", .maskCommand), 54: ("Right ⌘", .maskCommand),
        56: ("⇧ Shift", .maskShift), 60: ("Right ⇧", .maskShift),
        58: ("⌥ Option", .maskAlternate), 61: ("Right ⌥", .maskAlternate),
        59: ("⌃ Control", .maskControl), 62: ("Right ⌃", .maskControl),
        63: ("fn", .maskSecondaryFn), 57: ("Caps Lock", []),
    ]

    private static let table: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`",
        51: "Delete", 53: "Esc", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /", 76: "Enter",
        78: "Keypad -", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4",
        87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        114: "Help", 115: "Home", 116: "Page Up", 117: "Fwd Delete", 119: "End", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑", 179: "🌐 Globe",
    ]
}
