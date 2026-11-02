import AppKit
import SwiftUI

/// Never takes key focus, so clicking the island never steals the keyboard from your app.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// The resting island sits inside the menu bar, so AppKit must not push it below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
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
    static let compactWidth: CGFloat = 250
    static let expanded = CGSize(width: 480, height: 58)
    static let shelfRoom: CGFloat = 8 + 62     // gap + shelf strip under the expanded bar
    static let labelRoom: CGFloat = 38         // hover label under the expanded bar
    static let toast = CGSize(width: 380, height: 62)
    static let drop = CGSize(width: 360, height: 76)

    static func compact(barHeight: CGFloat) -> CGSize { CGSize(width: compactWidth, height: barHeight) }

    static func content(for mode: IslandMode, barHeight: CGFloat, shelf: Bool) -> CGSize {
        switch mode {
        case .compact: compact(barHeight: barHeight)
        case .expanded: CGSize(width: expanded.width, height: expanded.height + (shelf ? shelfRoom : 0) + labelRoom)
        case .toast: toast
        case .drop: drop
        }
    }

    /// Menu bar thickness on `screen` (30 pt on this Mac's external display, ~37 under a notch).
    @MainActor static func menuBarHeight(_ s: NSScreen) -> CGFloat {
        let h = s.frame.maxY - s.visibleFrame.maxY
        return h > 0 ? h : max(NSStatusBar.system.thickness, 24)   // auto-hidden menu bar
    }
}

/// Floating "island" in the middle of the menu bar, level with the clock and the File / Edit menus.
/// It grows downward from there; the window is resized to the current mode so transparent margins
/// never swallow clicks meant for other apps or menu-bar items.
@MainActor
final class IslandController {
    let panel: IslandPanel
    private let model: AppModel
    private var shrinkWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var currentContent = CGSize(width: IslandMetrics.compactWidth, height: 24)
    private var capsuleTop: CGFloat = 0

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
        layout(content: size(for: .compact))
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.layout(content: self.size(for: self.model.islandMode))
            }
        }
    }

    /// Bottom edge of the resting capsule in screen coordinates; the board hangs below this.
    var barBottomY: CGFloat { capsuleTop - model.barHeight }
    /// The menu-bar screen; nil only mid display reconfiguration.
    var screen: NSScreen? { NSScreen.screens.first }

    private func hover(_ inside: Bool) {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.setIslandHover(inside) }
        hoverWork = work
        // Small intent delay in, a longer grace period out.
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.08 : 0.35), execute: work)
    }

    private func size(for mode: IslandMode) -> CGSize {
        IslandMetrics.content(for: mode, barHeight: model.barHeight, shelf: !model.shelf.isEmpty)
    }

    /// Re-measures after something that changes the current mode's size (shelf filled or emptied).
    func refit() {
        let target = size(for: model.islandMode)
        guard target != currentContent else { return }
        if target.height > currentContent.height || target.width > currentContent.width {
            layout(content: target)
        } else {
            didChange(to: model.islandMode)
        }
    }

    func willChange(to mode: IslandMode) {
        let target = size(for: mode)
        shrinkWork?.cancel()
        if target.width >= currentContent.width || target.height >= currentContent.height {
            layout(content: CGSize(width: max(target.width, currentContent.width), height: max(target.height, currentContent.height)))
        }
    }

    func didChange(to mode: IslandMode) {
        let target = size(for: mode)
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
        let menuBar = IslandMetrics.menuBarHeight(s)
        // Resting capsule: a few points shorter than the menu bar, centred in it vertically and horizontally.
        let bar = max(20, (menuBar - 6).rounded())
        if model.barHeight != bar { model.barHeight = bar; if model.islandMode == .compact { currentContent = size(for: .compact) } }
        capsuleTop = s.frame.maxY - ((menuBar - bar) / 2).rounded()
        let size = CGSize(width: currentContent.width + IslandMetrics.pad * 2, height: currentContent.height + IslandMetrics.pad * 2)
        let frame = NSRect(x: s.frame.midX - size.width / 2, y: capsuleTop + IslandMetrics.pad - size.height, width: size.width, height: size.height)
        panel.setFrame(frame.integral, display: true)
    }
}
