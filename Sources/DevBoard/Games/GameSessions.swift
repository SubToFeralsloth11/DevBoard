import AppKit
import SwiftUI

/// Runs Exam Quest arcade games in Godot for the play time bought on the site.
///
/// The site opens `devboard://play?dir=<folder under ~/Code>&secs=<seconds>&name=<title>`.
/// When the time runs out, or the site sends `devboard://end`, the island warns
/// "Save your game" and the game is closed 30 seconds later.
@MainActor
final class GameSessions {
    nonisolated static let warningSeconds = 30

    private weak var model: AppModel?
    private var process: Process?
    private var name = ""
    private var expiryTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?

    init(model: AppModel) { self.model = model }

    func handle(_ url: URL) {
        guard url.scheme == "devboard" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        switch url.host {
        case "play":
            guard let dir = query["dir"], let secs = Int(query["secs"] ?? ""), secs > 0 else { return }
            play(dir: dir, seconds: secs, name: query["name"] ?? dir)
        case "end":
            endSoon()
        default:
            break
        }
    }

    private func play(dir: String, seconds: Int, name: String) {
        // Only projects inside ~/Code, so a web page can't run arbitrary folders.
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Code").standardizedFileURL
        let project = root.appendingPathComponent(dir).standardizedFileURL
        guard project.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: project.appendingPathComponent("project.godot").path) else {
            toast("Can't open \(name)", "No Godot project at ~/Code/\(dir)", tint: DB.rec)
            return
        }
        guard let godot = Self.godotBinary() else {
            toast("Godot isn't installed", "Install Godot to play \(name) outside the browser", tint: DB.rec)
            return
        }

        stop()
        let p = Process()
        p.executableURL = godot
        p.arguments = ["--path", project.path]
        p.terminationHandler = { [weak self] ended in
            Task { @MainActor in self?.processEnded(ended) }
        }
        do { try p.run() } catch {
            toast("Couldn't start Godot", error.localizedDescription, tint: DB.rec)
            return
        }
        process = p
        self.name = name
        toast("Playing \(name)", "\(Self.clock(seconds)) of play time", tint: DB.mint, symbol: "gamecontroller.fill")

        let warnAfter = max(0, seconds - Self.warningSeconds)
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(warnAfter))
            guard !Task.isCancelled else { return }
            self?.endSoon(after: min(seconds, Self.warningSeconds))
        }
    }

    /// Warns, then closes the game. Repeated calls don't restart the countdown.
    private func endSoon(after seconds: Int = GameSessions.warningSeconds) {
        guard process?.isRunning == true, closeTask == nil else { return }
        expiryTask?.cancel()
        NSSound(named: "Funk")?.play()
        toast("Save your game", "\(name) closes in \(seconds) seconds", tint: DB.amber, symbol: "exclamationmark.triangle.fill", hold: Double(min(seconds, 20)))
        closeTask = Task { [weak self] in
            if seconds > 10 {
                try? await Task.sleep(for: .seconds(seconds - 10))
                guard !Task.isCancelled, let self else { return }
                self.toast("Save your game", "\(self.name) closes in 10 seconds", tint: DB.amber, symbol: "exclamationmark.triangle.fill", hold: 10)
            }
            try? await Task.sleep(for: .seconds(min(seconds, 10)))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private func close() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        Task {
            try? await Task.sleep(for: .seconds(3))
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func stop() {
        expiryTask?.cancel(); expiryTask = nil
        closeTask?.cancel(); closeTask = nil
        if let p = process, p.isRunning { p.terminationHandler = nil; p.terminate() }
        process = nil
    }

    private func processEnded(_ p: Process) {
        guard p === process else { return }
        let timedOut = closeTask != nil
        expiryTask?.cancel(); expiryTask = nil
        closeTask?.cancel(); closeTask = nil
        process = nil
        toast(timedOut ? "Play time is up" : "\(name) closed", "Back to Exam Quest to earn more time", tint: DB.accent, symbol: "book.fill")
    }

    private func toast(_ title: String, _ subtitle: String, tint: Color, symbol: String = "gamecontroller.fill", hold: Double = 5) {
        model?.showToast(Toast(symbol: symbol, title: title, subtitle: subtitle, tint: tint), seconds: hold)
    }

    private static func clock(_ s: Int) -> String { "\(s / 60):" + String(format: "%02d", s % 60) }

    private static func godotBinary() -> URL? {
        let candidates = ["/opt/homebrew/bin/godot", "/usr/local/bin/godot",
                          "/Applications/Godot.app/Contents/MacOS/Godot"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }
}
