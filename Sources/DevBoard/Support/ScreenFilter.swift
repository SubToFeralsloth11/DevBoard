import AppKit
import CoreGraphics

enum ScreenTint: String, CaseIterable, Identifiable {
    case off, warm, cool

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .warm: "Warm"
        case .cool: "Cool"
        }
    }
    var symbol: String {
        switch self {
        case .off: "circle.slash"
        case .warm: "sun.max.fill"
        case .cool: "snowflake"
        }
    }
}

/// Tints every display warm (orange, like Night Shift) or cool (blue) by scaling each colour channel's
/// gamma ramp. macOS puts the normal colours back when DevBoard quits.
@MainActor
final class ScreenFilter {
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
        // macOS resets gamma ramps when displays change or wake, so reapply then.
        let reapply: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: reapply)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: reapply)
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: reapply)
    }

    /// Channel maxima (red, green, blue) for the current tint and strength.
    var channels: (Float, Float, Float) {
        let s = Float(min(max(settings.screenTintStrength, 0), 1))
        switch settings.screenTint {
        case .off: return (1, 1, 1)
        case .warm: return (1, 1 - 0.24 * s, 1 - 0.55 * s)
        case .cool: return (1 - 0.32 * s, 1 - 0.12 * s, 1)
        }
    }

    func apply() {
        guard settings.screenTint != .off else {
            CGDisplayRestoreColorSyncSettings()
            return
        }
        let (r, g, b) = channels
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        for id in ids.prefix(Int(count)) {
            CGSetDisplayTransferByFormula(id, 0, r, 1, 0, g, 1, 0, b, 1)
        }
    }

    /// Off → Warm → Cool → Off.
    func cycle() {
        let all = ScreenTint.allCases
        settings.screenTint = all[(all.firstIndex(of: settings.screenTint)! + 1) % all.count]
        apply()
    }
}
