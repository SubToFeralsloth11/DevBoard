import AppKit
import Observation
import SwiftUI

enum BoardTab: String, CaseIterable, Identifiable {
    case agents, school, files, monitor, clips, activity, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .agents: "Agents"
        case .school: "School"
        case .files: "Files"
        case .monitor: "Monitor"
        case .clips: "Clips"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .agents: "sparkles.rectangle.stack"
        case .school: "graduationcap"
        case .files: "tray.full"
        case .monitor: "gauge.with.dots.needle.67percent"
        case .clips: "film.stack"
        case .activity: "chart.bar.xaxis"
        case .settings: "slider.horizontal.3"
        }
    }
}

enum IslandMode: Equatable {
    /// `.drop` turns the island into a drop zone while you drag files anywhere on the Mac.
    case compact, expanded, toast, drop
}

enum ToastAction: Equatable {
    case openClip(URL)
    case openAgent(String)
    case openPrivacySettings
    case openSettings
    case openSchool
    case openSchoolTask(String)
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
    case toggleBoard, openAgents, openSchool, openFiles, openMonitor, openClips, openActivity, openSettings
    case screenshotRegion, screenshotWindow, screenshotScreen
    case toggleRecording, saveReplay, toggleReplay
    case toggleIsland, cycleScreenTint, quit
}

/// Root state shared by the island, the board and the services.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let settings = SettingsStore()
    let monitor = SystemMonitor()
    let library = ClipLibrary()
    let agents = AgentScanner()
    let shelf = Shelf()
    let fileSearch: FileSearch
    let daymap: DayMapService
    let activity = ActivityTracker()
    let screenFilter: ScreenFilter
    @ObservationIgnored private(set) lazy var capture = CaptureEngine(model: self)
    @ObservationIgnored private(set) lazy var games = GameSessions(model: self)

    var boardTab: BoardTab = .agents {
        didSet { monitor.detailed = boardShown && boardTab == .monitor }
    }
    /// Drives the board's in/out animation; the controller orders the window.
    var boardShown = false {
        didSet {
            monitor.detailed = boardShown && boardTab == .monitor
            if boardShown != oldValue { refreshIslandMode() }
        }
    }
    var boardPinned = false
    var islandMode: IslandMode = .compact
    var islandHidden = false
    var toast: Toast?
    var editingClip: ClipItem?
    var focusedAgentID: String?
    var focusedTaskID: String?
    /// Bumped to move keyboard focus into the Files search field.
    var focusSearchToken = 0
    /// Height of the island's resting capsule, matched to the menu bar it sits in.
    var barHeight: CGFloat = 24
    /// Files are being dragged somewhere on screen (from another app).
    var fileDragActive = false
    /// A shelf item is being dragged out of the island; keep the shelf open until it lands.
    var shelfDragging = false

    @ObservationIgnored weak var board: BoardController?
    @ObservationIgnored weak var island: IslandController?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var hovering = false
    @ObservationIgnored private var hoverSince = Date.distantPast
    @ObservationIgnored private var toastSince = Date.distantPast
    @ObservationIgnored let dragWatcher = FileDragWatcher()

    private init() {
        daymap = DayMapService(settings: settings)
        fileSearch = FileSearch(settings: settings)
        screenFilter = ScreenFilter(settings: settings)
        daymap.onToast = { [weak self] toast in
            NSSound(named: "Purr")?.play()
            self?.showToast(toast, seconds: 6)
        }
        shelf.onChange = { [weak self] in self?.island?.refit() }
        dragWatcher.ignore = { [weak self] in self?.shelfDragging == true }
        dragWatcher.onChange = { [weak self] active in
            guard let self else { return }
            self.fileDragActive = active
            self.refreshIslandMode()
        }
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
        if hover && !hovering { hoverSince = .now }
        hovering = hover
        refreshIslandMode()
    }

    /// The pointer arrived after the toast did, i.e. the user is reaching for the toast.
    private var hoverIsOnToast: Bool { toast != nil && hovering && hoverSince > toastSince }

    /// Toasts stay up while the pointer rests on them so their action stays clickable.
    func showToast(_ toast: Toast, seconds: Double = 3.2) {
        self.toast = toast
        toastSince = .now
        refreshIslandMode()
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            var held = false
            while !Task.isCancelled, self?.hoverIsOnToast == true {
                held = true
                try? await Task.sleep(for: .milliseconds(250))
            }
            if held { try? await Task.sleep(for: .seconds(1.2)) }
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

    /// If you were already using the expanded bar when a toast arrives (e.g. you just pressed Record),
    /// the bar stays put and the toast waits; otherwise the toast wins so it can be clicked.
    /// Hover never expands the island while the board hangs below it. Dragging files anywhere turns it
    /// into a drop zone; dragging a shelf item out keeps the bar (and its shelf) open until it lands.
    func refreshIslandMode() {
        let wantsBar = (hovering || shelfDragging) && !boardShown && !hoverIsOnToast
        let next: IslandMode = fileDragActive && !shelfDragging ? .drop
            : wantsBar ? .expanded : (toast != nil ? .toast : .compact)
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
        case .openSchool:
            openBoard(.school)
        case .openSchoolTask(let id):
            focusedTaskID = id
            openBoard(.school)
        }
    }

    // MARK: Files

    /// HTML pages (and folders with an index.html) open in DevBoard; everything else in its usual app.
    func openFile(_ url: URL) {
        if FileKind.webEntry(for: url) != nil { WebWindows.shared.openFile(url) } else { NSWorkspace.shared.open(url) }
    }

    func dropOnShelf(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        withAnimation(DB.spring) { shelf.add(urls) }
        NSSound(named: "Pop")?.play()
        showToast(Toast(symbol: "tray.full.fill",
                        title: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files on the shelf",
                        subtitle: "Hover the island to drag \(urls.count == 1 ? "it" : "them") back out", tint: DB.mint), seconds: 2.2)
    }

    /// Keeps the island's shelf open while a shelf item is being dragged out.
    func beginShelfDrag() {
        guard !shelfDragging else { return }
        shelfDragging = true
        refreshIslandMode()
        Task { [weak self] in
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(120)) }
            guard let self else { return }
            self.shelfDragging = false
            self.refreshIslandMode()
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
        case .openSchool: toggleBoard(.school)
        case .openFiles:
            if boardShown && boardTab == .files { board?.hide() } else { openBoard(.files); focusSearchToken += 1 }
        case .openMonitor: toggleBoard(.monitor)
        case .openClips: toggleBoard(.clips)
        case .openActivity: toggleBoard(.activity)
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
        case .cycleScreenTint:
            screenFilter.cycle()
            let tint = settings.screenTint
            showToast(Toast(symbol: tint.symbol, title: tint == .off ? "Screen filter off" : "\(tint.title) screen filter",
                            subtitle: "⌥⇧W switches Off → Warm → Cool",
                            tint: tint == .warm ? DB.amber : tint == .cool ? DB.accent : .secondary), seconds: 2)
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
