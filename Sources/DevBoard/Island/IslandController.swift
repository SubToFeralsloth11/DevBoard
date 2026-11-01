import AppKit
import SwiftUI

/// Never takes key focus, so clicking the island never steals the keyboard from your app.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view with an always-active tracking area (SwiftUI hover is unreliable in non-key panels).
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum IslandMetrics {
    static let pad: CGFloat = 18               // transparent room for the glass shadow
    static let compact = CGSize(width: 188, height: 34)
    static let expanded = CGSize(width: 432, height: 58)
    static let labelRoom: CGFloat = 38         // hover label under the expanded bar
    static let toast = CGSize(width: 380, height: 62)
    static let topGap: CGFloat = 6             // below the menu bar

    static func content(for mode: IslandMode) -> CGSize {
        switch mode {
        case .compact: compact
        case .expanded: CGSize(width: expanded.width, height: expanded.height + labelRoom)
        case .toast: toast
        }
    }
}

/// Floating "island" at the top centre of the menu-bar screen. The window is resized to the
/// current mode so transparent margins never swallow clicks meant for other apps.
@MainActor
final class IslandController {
    let panel: IslandPanel
    private let model: AppModel
    private var shrinkWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var currentContent = IslandMetrics.content(for: .compact)

    init(model: AppModel) {
        self.model = model
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let host = HoverHostingView(rootView: IslandView(model: model))
        host.sizingOptions = []
        host.onHover = { [weak self] inside in self?.hover(inside) }
        panel.contentView = host

        layout(content: currentContent)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout(content: self?.currentContent ?? IslandMetrics.compact) }
        }
    }

    /// Bottom edge of the island bar in screen coordinates; the board hangs below this.
    var barBottomY: CGFloat { panel.frame.maxY - IslandMetrics.pad - IslandMetrics.compact.height }
    /// The menu-bar screen; nil only mid display reconfiguration.
    var screen: NSScreen? { NSScreen.screens.first }

    private func hover(_ inside: Bool) {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.setIslandHover(inside) }
        hoverWork = work
        // Small intent delay in, a longer grace period out.
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.08 : 0.35), execute: work)
    }

    func willChange(to mode: IslandMode) {
        let target = IslandMetrics.content(for: mode)
        shrinkWork?.cancel()
        if target.width >= currentContent.width || target.height >= currentContent.height {
            layout(content: CGSize(width: max(target.width, currentContent.width), height: max(target.height, currentContent.height)))
        }
    }

    func didChange(to mode: IslandMode) {
        let target = IslandMetrics.content(for: mode)
        guard target != currentContent else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.islandMode == mode else { return }
            self.layout(content: target)
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    func setHidden(_ hidden: Bool) {
        if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    private func layout(content: CGSize) {
        currentContent = content
        guard let s = screen else { return }
        let menuBarBottom = s.visibleFrame.maxY
        let size = CGSize(width: content.width + IslandMetrics.pad * 2, height: content.height + IslandMetrics.pad * 2)
        let top = menuBarBottom - IslandMetrics.topGap + IslandMetrics.pad
        let frame = NSRect(x: s.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        panel.setFrame(frame.integral, display: true)
    }
}
