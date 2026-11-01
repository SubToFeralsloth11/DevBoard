import AppKit
import Carbon.HIToolbox

@main
enum DevBoardMain {
    static func main() {
        if MainActor.assumeIsolated({ IconRenderer.renderIfRequested() }) { return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.shared
    private var island: IslandController?
    private var board: BoardController?
    private var hotkeys: HotkeyCenter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.library.reload()
        model.agents.windowMinutes = model.settings.agentWindowMinutes
        model.agents.start()
        model.monitor.start()

        let island = IslandController(model: model)
        let board = BoardController(model: model)
        model.island = island
        model.board = board
        self.island = island
        self.board = board

        let hk = HotkeyCenter()
        let m = model
        hk.register(kVK_ANSI_D) { m.perform(.toggleBoard) }
        hk.register(kVK_ANSI_A) { m.perform(.openAgents) }
        hk.register(kVK_ANSI_M) { m.perform(.openMonitor) }
        hk.register(kVK_ANSI_C) { m.perform(.openClips) }
        hk.register(kVK_ANSI_S) { m.perform(.screenshotRegion) }
        hk.register(kVK_ANSI_R) { m.perform(.toggleRecording) }
        hk.register(kVK_ANSI_X) { m.perform(.saveReplay) }
        hk.register(kVK_ANSI_H) { m.perform(.toggleIsland) }
        hotkeys = hk

        if model.settings.replayEnabled {
            Task { await model.capture.syncStream() }
        }

        // Pause the replay stream while the Mac sleeps; resume on wake.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await AppModel.shared.capture.shutdown() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await AppModel.shared.capture.syncStream()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }
}
