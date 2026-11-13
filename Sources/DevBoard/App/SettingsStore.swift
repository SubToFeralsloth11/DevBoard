import Foundation
import Observation
import ServiceManagement

enum ReplayQuality: Int, CaseIterable, Identifiable {
    case p720 = 720
    case p1080 = 1080
    case p1440 = 1440

    var id: Int { rawValue }
    var label: String { "\(rawValue)p" }

    /// Average H.264 bitrate at 60 fps; halved-ish for 30 fps by the caller.
    var bitrate60: Int {
        switch self {
        case .p720: 6_000_000
        case .p1080: 12_000_000
        case .p1440: 20_000_000
        }
    }
}

/// Persisted user preferences. Every property writes through to UserDefaults.
@MainActor @Observable
final class SettingsStore {
    @ObservationIgnored private let d = UserDefaults.standard

    var replayEnabled: Bool { didSet { d.set(replayEnabled, forKey: K.replayEnabled) } }
    var replaySeconds: Int { didSet { d.set(replaySeconds, forKey: K.replaySeconds) } }
    var quality: ReplayQuality { didSet { d.set(quality.rawValue, forKey: K.quality) } }
    var fps: Int { didSet { d.set(fps, forKey: K.fps) } }
    var systemAudio: Bool { didSet { d.set(systemAudio, forKey: K.systemAudio) } }
    var microphone: Bool { didSet { d.set(microphone, forKey: K.microphone) } }
    var showCursor: Bool { didSet { d.set(showCursor, forKey: K.showCursor) } }
    var hideSelfInCaptures: Bool { didSet { d.set(hideSelfInCaptures, forKey: K.hideSelf) } }
    var copyScreenshots: Bool { didSet { d.set(copyScreenshots, forKey: K.copyScreenshots) } }
    var agentNotifications: Bool { didSet { d.set(agentNotifications, forKey: K.agentNotify) } }
    var agentWindowMinutes: Int { didSet { d.set(agentWindowMinutes, forKey: K.agentWindow) } }
    var displayID: UInt32 { didSet { d.set(Int(displayID), forKey: K.displayID) } }
    var daymapURL: String { didSet { d.set(daymapURL, forKey: K.daymapURL) } }
    var rummagePath: String { didSet { d.set(rummagePath, forKey: K.rummagePath) } }
    var schoolReminders: Bool { didSet { d.set(schoolReminders, forKey: K.schoolReminders) } }
    var lessonReminders: Bool { didSet { d.set(lessonReminders, forKey: K.lessonReminders) } }
    var screenTint: ScreenTint { didSet { d.set(screenTint.rawValue, forKey: K.screenTint) } }
    var screenTintStrength: Double { didSet { d.set(screenTintStrength, forKey: K.screenTintStrength) } }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private enum K {
        static let replayEnabled = "replayEnabled", replaySeconds = "replaySeconds", quality = "quality"
        static let fps = "fps", systemAudio = "systemAudio", microphone = "microphone", showCursor = "showCursor"
        static let hideSelf = "hideSelfInCaptures", copyScreenshots = "copyScreenshots"
        static let agentNotify = "agentNotifications", agentWindow = "agentWindowMinutes", displayID = "displayID"
        static let daymapURL = "daymapURL", schoolReminders = "schoolReminders", lessonReminders = "lessonReminders"
        static let rummagePath = "rummagePath", screenTint = "screenTint", screenTintStrength = "screenTintStrength"
    }

    init() {
        d.register(defaults: [
            K.replayEnabled: true, K.replaySeconds: 30, K.quality: ReplayQuality.p1080.rawValue, K.fps: 60,
            K.systemAudio: true, K.microphone: false, K.showCursor: true, K.hideSelf: true,
            K.copyScreenshots: true, K.agentNotify: true, K.agentWindow: 30, K.displayID: 0,
            K.daymapURL: "https://thegapshs.eq.daymap.net", K.schoolReminders: true, K.lessonReminders: true,
            K.rummagePath: "~/code/rummage", K.screenTint: ScreenTint.off.rawValue, K.screenTintStrength: 0.6,
        ])
        replayEnabled = d.bool(forKey: K.replayEnabled)
        replaySeconds = d.integer(forKey: K.replaySeconds)
        quality = ReplayQuality(rawValue: d.integer(forKey: K.quality)) ?? .p1080
        fps = d.integer(forKey: K.fps)
        systemAudio = d.bool(forKey: K.systemAudio)
        microphone = d.bool(forKey: K.microphone)
        showCursor = d.bool(forKey: K.showCursor)
        hideSelfInCaptures = d.bool(forKey: K.hideSelf)
        copyScreenshots = d.bool(forKey: K.copyScreenshots)
        agentNotifications = d.bool(forKey: K.agentNotify)
        agentWindowMinutes = d.integer(forKey: K.agentWindow)
        displayID = UInt32(d.integer(forKey: K.displayID))
        daymapURL = d.string(forKey: K.daymapURL) ?? ""
        rummagePath = d.string(forKey: K.rummagePath) ?? "~/code/rummage"
        schoolReminders = d.bool(forKey: K.schoolReminders)
        lessonReminders = d.bool(forKey: K.lessonReminders)
        screenTint = ScreenTint(rawValue: d.string(forKey: K.screenTint) ?? "") ?? .off
        screenTintStrength = d.double(forKey: K.screenTintStrength)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Bitrate for the current quality and frame rate.
    var bitrate: Int { fps >= 60 ? quality.bitrate60 : quality.bitrate60 * 6 / 10 }
}
