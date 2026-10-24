import AppKit
import SwiftUI

/// Borderless, non-activating floating panel: clicking it never takes focus away from Slack,
/// so ⌘V works right after Copy.
final class OverlayPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: OverlayController.width, height: 200),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets clicks land on buttons even though the panel never becomes key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OverlayController {
    static let width: CGFloat = 380

    private let panel = OverlayPanel()
    private let hosting: FirstMouseHostingView<OverlayView>
    private var anchor: CGRect?
    private var relayoutScheduled = false

    init(model: AppModel) {
        hosting = FirstMouseHostingView(rootView: OverlayView(model: model, onSizeChange: {}))
        hosting.rootView = OverlayView(model: model) { [weak self] in self?.scheduleRelayout() }
        panel.contentView = hosting
    }

    func show(anchor: CGRect?) {
        if let anchor { self.anchor = anchor }
        relayout()
        guard !panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func update(anchor: CGRect?) {
        guard let anchor, anchor != self.anchor else { return }
        self.anchor = anchor
        relayout()
    }

    func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.orderOut(nil) }
        })
    }

    private func scheduleRelayout() {
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.relayoutScheduled = false
                self?.relayout()
            }
        }
    }

    private func relayout() {
        let height = max(60, hosting.fittingSize.height)
        panel.setFrame(frame(for: CGSize(width: Self.width, height: height)), display: true)
    }

    /// Docks outside the right edge of the anchor when there's room, otherwise inside its top-right corner.
    private func frame(for size: CGSize) -> CGRect {
        let screen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var origin: CGPoint
        if let anchor {
            let top = min(anchor.maxY - 12, visible.maxY - 8)
            if anchor.maxX + 12 + size.width <= visible.maxX {
                origin = CGPoint(x: anchor.maxX + 12, y: top - size.height)
            } else {
                origin = CGPoint(x: anchor.maxX - size.width - 24, y: top - size.height)
            }
        } else {
            origin = CGPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = max(origin.y, visible.minY + 8)
        return CGRect(origin: origin, size: CGSize(width: size.width, height: min(size.height, visible.height - 16)))
    }
}
