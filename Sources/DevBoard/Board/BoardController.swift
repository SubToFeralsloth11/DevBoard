import AppKit
import SwiftUI

final class BoardPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

enum BoardMetrics {
    static let size = CGSize(width: 980, height: 660)
    static let shadowPad: CGFloat = 30
}

/// The glass board that drops down from the island.
@MainActor
final class BoardController: NSObject, NSWindowDelegate {
    let panel: BoardPanel
    private let model: AppModel
    private var hideWork: DispatchWorkItem?

    init(model: AppModel) {
        self.model = model
        let full = CGSize(width: BoardMetrics.size.width + BoardMetrics.shadowPad * 2,
                          height: BoardMetrics.size.height + BoardMetrics.shadowPad * 2)
        panel = BoardPanel(contentRect: NSRect(origin: .zero, size: full),
                           styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.escape() }
        let host = NSHostingView(rootView: BoardView(model: model))
        host.sizingOptions = []
        panel.contentView = host
    }

    func show() {
        hideWork?.cancel()
        position()
        panel.orderFrontRegardless()
        panel.makeKey()
        withAnimation(DB.spring) { model.boardShown = true }
    }

    func hide() {
        withAnimation(.smooth(duration: 0.22)) { model.boardShown = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.boardShown else { return }
            self.panel.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: work)
    }

    private func escape() {
        if model.editingClip != nil {
            withAnimation(DB.spring) { model.editingClip = nil }
        } else if model.focusedAgentID != nil {
            withAnimation(DB.spring) { model.focusedAgentID = nil }
        } else {
            hide()
        }
    }

    private func position() {
        let screen = model.island?.screen ?? NSScreen.screens.first ?? NSScreen.main!
        let top = (model.island?.barBottomY ?? screen.visibleFrame.maxY) - 10 + BoardMetrics.shadowPad
        let f = panel.frame
        let x = screen.frame.midX - f.width / 2
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: (top - f.height).rounded()))
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else closes the board, unless pinned or a sheet/menu is up.
        guard !model.boardPinned, model.boardShown, panel.attachedSheet == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, !self.panel.isKeyWindow, self.model.boardShown, !self.model.boardPinned else { return }
            if NSApp.modalWindow != nil { return }
            self.hide()
        }
    }
}
