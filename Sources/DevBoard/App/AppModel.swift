import AppKit
import Observation
import SwiftUI

enum BoardTab: String, CaseIterable, Identifiable {
    case agents, monitor, clips, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .agents: "Agents"
        case .monitor: "Monitor"
        case .clips: "Clips"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .agents: "sparkles.rectangle.stack"
        case .monitor: "gauge.with.dots.needle.67percent"
        case .clips: "film.stack"
        case .settings: "slider.horizontal.3"
        }
    }
}

enum IslandMode: Equatable {
    case compact, expanded, toast
}

enum ToastAction: Equatable {
    case openClip(URL)
    case openAgent(String)
    case openPrivacySettings
    case openSettings
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var title: String
    var subtitle: String? = nil
    var tint: Color = DB.accent
    var thumbnail: NSImage? = nil
    var action: ToastAction? = nil
}

/// Everything DevBoard can do from the island, hotkeys or the board.
enum DevAction {
    case toggleBoard, openAgents, openMonitor, openClips, openSettings
    case screenshotRegion, screenshotWindow, screenshotScreen
    case toggleRecording, saveReplay, toggleReplay
    case toggleIsland, quit
}

/// Root state shared by the island, the board and the services.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let settings = SettingsStore()
    let monitor = SystemMonitor()
    let library = ClipLibrary()
    let agents = AgentScanner()
    @ObservationIgnored private(set) lazy var capture = CaptureEngine(model: self)

    var boardTab: BoardTab = .agents {
        didSet { monitor.detailed = boardShown && boardTab == .monitor }
    }
    /// Drives the board's in/out animation; the controller orders the window.
    var boardShown = false {
        didSet { monitor.detailed = boardShown && boardTab == .monitor }
    }
    var boardPinned = false
    var islandMode: IslandMode = .compact
    var islandHidden = false
    var toast: Toast?
    var editingClip: ClipItem?
    var focusedAgentID: String?

    @ObservationIgnored weak var board: BoardController?
    @ObservationIgnored weak var island: IslandController?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var hovering = false

    private init() {
        agents.onAgentFinished = { [weak self] agent in
            guard let self, self.settings.agentNotifications else { return }
            NSSound(named: "Glass")?.play()
            self.showToast(Toast(symbol: "checkmark.seal.fill", title: "\(agent.displayName) finished",
                                 subtitle: agent.title.isEmpty ? "Waiting for you" : agent.title,
                                 tint: DB.mint, action: .openAgent(agent.id)))
        }
    }

    // MARK: Island

    func setIslandHover(_ hover: Bool) {
        hovering = hover
        refreshIslandMode()
    }

    func showToast(_ toast: Toast, seconds: Double = 3.2) {
        self.toast = toast
        refreshIslandMode()
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.toast = nil
            self.refreshIslandMode()
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
        refreshIslandMode()
    }

    private func refreshIslandMode() {
        let next: IslandMode = hovering ? .expanded : (toast != nil ? .toast : .compact)
        guard next != islandMode else { return }
        island?.willChange(to: next)
        withAnimation(DB.spring) { islandMode = next }
        island?.didChange(to: next)
    }

    func runToastAction(_ action: ToastAction) {
        dismissToast()
        switch action {
        case .openClip(let url):
            library.reload()
            editingClip = library.items.first { $0.url == url } ?? ClipItem(url: url)
            openBoard(.clips)
        case .openAgent(let id):
            focusedAgentID = id
            openBoard(.agents)
        case .openPrivacySettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        case .openSettings:
            openBoard(.settings)
        }
    }

    // MARK: Board

    func openBoard(_ tab: BoardTab) {
        boardTab = tab
        if !boardShown { board?.show() }
    }

    func toggleBoard(_ tab: BoardTab? = nil) {
        if boardShown, tab == nil || tab == boardTab {
            board?.hide()
        } else {
            openBoard(tab ?? boardTab)
        }
    }

    func closeBoard() {
        if boardShown { board?.hide() }
    }

    // MARK: Actions

    func perform(_ action: DevAction) {
        switch action {
        case .toggleBoard: toggleBoard()
        case .openAgents: toggleBoard(.agents)
        case .openMonitor: toggleBoard(.monitor)
        case .openClips: toggleBoard(.clips)
        case .openSettings: toggleBoard(.settings)
        case .screenshotRegion: closeBoard(); capture.screenshot(.region)
        case .screenshotWindow: closeBoard(); capture.screenshot(.window)
        case .screenshotScreen: closeBoard(); capture.screenshot(.screen)
        case .toggleRecording: Task { await capture.toggleRecording() }
        case .saveReplay: Task { await capture.saveReplay() }
        case .toggleReplay:
            settings.replayEnabled.toggle()
            Task { await capture.syncStream() }
            showToast(Toast(symbol: settings.replayEnabled ? "memories" : "pause.circle",
                            title: settings.replayEnabled ? "Instant replay on" : "Instant replay off",
                            subtitle: settings.replayEnabled ? "⌥⇧X saves the last \(settings.replaySeconds)s" : nil,
                            tint: settings.replayEnabled ? DB.amber : .secondary))
        case .toggleIsland:
            islandHidden.toggle()
            island?.setHidden(islandHidden)
        case .quit:
            Task {
                await capture.shutdown()
                NSApp.terminate(nil)
            }
        }
    }
}
