import AppKit
import Observation
import SwiftUI
import WebKit

/// Browser windows inside DevBoard: local HTML previews (with their CSS/JS/images) and DayMap pages.
/// All windows share the default website data store, so DayMap stays signed in across them.
@MainActor
final class WebWindows {
    static let shared = WebWindows()
    private var open: [WebWindowController] = []

    /// Opens a local page with read access to its project, so relative links (../css, ./js, images,
    /// fetch() of local JSON, ES modules) resolve. Reloads itself when files in that project change.
    func openFile(_ url: URL) {
        guard let entry = FileKind.webEntry(for: url) else { NSWorkspace.shared.open(url); return }
        if let existing = open.first(where: { $0.state.fileEntry == entry }) {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let c = WebWindowController(state: WebState(fileEntry: entry, readRoot: Self.projectRoot(for: entry)))
        present(c)
    }

    /// Opens a web page (DayMap). `onNavigate` sees every finished navigation.
    @discardableResult
    func openPage(_ url: URL, onNavigate: ((URL) -> Void)? = nil) -> WebWindowController {
        let c = WebWindowController(state: WebState(page: url))
        c.state.onNavigate = onNavigate
        present(c)
        return c
    }

    private func present(_ c: WebWindowController) {
        open.append(c)
        c.onClose = { [weak self, weak c] in self?.open.removeAll { $0 === c } }
        c.window.center()
        if let last = open.dropLast().last?.window {
            c.window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 28, y: last.frame.maxY - 28))
        }
        c.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        c.state.start()
    }

    /// Nearest folder above the page that looks like a project (git repo, package.json, Godot export…);
    /// otherwise the page's own folder. Never wider than the home folder.
    static func projectRoot(for file: URL) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let fm = FileManager.default
        var dir = file.deletingLastPathComponent().standardizedFileURL
        let own = dir
        while dir.path != home, dir.path != "/" {
            for marker in [".git", "package.json", "project.godot", "vite.config.js", "vite.config.ts"]
            where fm.fileExists(atPath: dir.appendingPathComponent(marker).path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return own
    }
}

@MainActor @Observable
final class WebState: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let fileEntry: URL?
    let readRoot: URL?
    private let page: URL?
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var loading = false
    var progress = 0.0
    var autoReload = true
    var lastReload: Date?
    @ObservationIgnored var onNavigate: ((URL) -> Void)?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(fileEntry: URL? = nil, readRoot: URL? = nil, page: URL? = nil) {
        self.fileEntry = fileEntry
        self.readRoot = readRoot
        self.page = page
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Let local pages load their own files the way a dev server would.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")   // right-click → Inspect Element
        config.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] wv, _ in MainActor.assumeIsolated { self?.progress = wv.estimatedProgress } },
            webView.observe(\.isLoading) { [weak self] wv, _ in MainActor.assumeIsolated { self?.loading = wv.isLoading } },
            webView.observe(\.title) { [weak self] wv, _ in MainActor.assumeIsolated { self?.title = wv.title ?? "" } },
            webView.observe(\.canGoBack) { [weak self] wv, _ in MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] wv, _ in MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward } },
        ]
    }

    var subtitle: String {
        if let fileEntry, let readRoot {
            let rel = fileEntry.path.replacingOccurrences(of: readRoot.deletingLastPathComponent().path + "/", with: "")
            return rel
        }
        return webView.url?.host() ?? page?.host() ?? ""
    }

    func start() {
        if let fileEntry, let readRoot {
            webView.loadFileURL(fileEntry, allowingReadAccessTo: readRoot)
            watcher = FileWatcher(path: readRoot.path, latency: 0.25, queue: .main) { [weak self] paths in
                let relevant = paths.contains { !$0.contains("/.git/") && !$0.contains("/node_modules/") && !$0.hasSuffix(".DS_Store") }
                guard relevant else { return }
                MainActor.assumeIsolated { self?.fileChanged() }
            }
        } else if let page {
            webView.load(URLRequest(url: page))
        }
    }

    private func fileChanged() {
        guard autoReload else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.webView.reloadFromOrigin()
            self.lastReload = .now
        }
    }

    func reload() { webView.reloadFromOrigin() }

    func openExternally() {
        if let fileEntry { NSWorkspace.shared.open(fileEntry) } else if let u = webView.url ?? page { NSWorkspace.shared.open(u) }
    }

    func teardown() {
        watcher = nil
        reloadTask?.cancel()
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    // MARK: WebKit

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let u = webView.url { onNavigate?(u) }
    }

    /// target=_blank links open in the same window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let a = NSAlert()
        a.messageText = message
        a.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        return p.runModal() == .OK ? p.urls : nil
    }
}

@MainActor
final class WebWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let state: WebState
    var onClose: (() -> Void)?

    init(state: WebState) {
        self.state = state
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        window.delegate = self
        window.contentView = NSHostingView(rootView: WebChrome(state: state))
        window.title = state.fileEntry?.lastPathComponent ?? "DayMap"
    }

    func windowWillClose(_ notification: Notification) {
        state.teardown()
        onClose?()
    }
}

private struct WebChrome: View {
    let state: WebState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Color.clear.frame(width: 64, height: 1)   // traffic lights
                BubbleButton(symbol: "chevron.left", help: "Back", tint: state.canGoBack ? .primary : .secondary, size: 28) { state.webView.goBack() }
                BubbleButton(symbol: "chevron.right", help: "Forward", tint: state.canGoForward ? .primary : .secondary, size: 28) { state.webView.goForward() }
                BubbleButton(symbol: "arrow.clockwise", help: "Reload (⌘R)", size: 28) { state.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.title.isEmpty ? (state.fileEntry?.lastPathComponent ?? "Loading…") : state.title)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(state.subtitle).font(.system(size: 10.5, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.leading, 4)
                Spacer(minLength: 8)
                if state.fileEntry != nil {
                    if let t = state.lastReload {
                        TimelineView(.periodic(from: t, by: 1)) { ctx in
                            Text("Reloaded \(Fmt.ago(t, now: ctx.date))").font(.system(size: 10.5, design: .rounded)).foregroundStyle(.tertiary)
                        }
                    }
                    Toggle("Live reload", isOn: Binding(get: { state.autoReload }, set: { state.autoReload = $0 }))
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .help("Reload when any file in the project changes")
                    BubbleButton(symbol: "folder", help: "Show in Finder", size: 28) {
                        if let f = state.fileEntry { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                    }
                }
                BubbleButton(symbol: "safari", help: "Open in your browser", size: 28) { state.openExternally() }
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Capsule().fill(DB.accent)
                        .frame(width: geo.size.width * state.progress, height: 2)
                        .opacity(state.loading ? 1 : 0)
                        .animation(DB.soft, value: state.progress)
                }
                .frame(height: 2)
            }
            WebViewHost(webView: state.webView)
        }
        .ignoresSafeArea()
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
