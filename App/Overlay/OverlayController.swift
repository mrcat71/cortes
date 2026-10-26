import AppKit
import SwiftUI
import CortesKit

@Observable
final class OverlayLayout {
    var width: CGFloat = OverlayController.width
    var height: CGFloat = 200
    var presentationID = UUID()
}

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
    private let layout = OverlayLayout()
    private var anchor: CGRect?
    private var composer: CGRect?
    private var protectedFrames: [CGRect] = []
    private var contentHeight: CGFloat = 200
    private var wantsVisible = false
    private weak var model: AppModel?
    private var relayoutScheduled = false

    init(model: AppModel) {
        self.model = model
        hosting = FirstMouseHostingView(rootView: OverlayView(model: model, layout: layout, onSizeChange: { _ in }))
        hosting.rootView = OverlayView(model: model, layout: layout) { [weak self] height in
            guard let self, abs(self.contentHeight - height) > 0.5 else { return }
            self.contentHeight = height
            self.scheduleRelayout()
        }
        // Placement owns the window size; SwiftUI must not add competing window size constraints.
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    func show(snapshot: ConversationSnapshot?, fallbackAnchor: CGRect?) {
        anchor = snapshot?.anchorFrame ?? fallbackAnchor
        composer = snapshot?.composerFrame
        protectedFrames = snapshot?.protectedFrames ?? []
        layout.presentationID = UUID()
        wantsVisible = true
        relayout()
    }

    func update(snapshot: ConversationSnapshot) {
        anchor = snapshot.anchorFrame
        composer = snapshot.composerFrame
        protectedFrames = snapshot.protectedFrames
        relayout()
    }

    func hide() {
        wantsVisible = false
        anchor = nil
        composer = nil
        protectedFrames = []
        model?.overlayPlacementUnavailable = false
        panel.orderOut(nil)
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
        guard wantsVisible else { return }
        let target = composer ?? anchor
        guard let screen = target.flatMap({ rect in
            NSScreen.screens.max { lhs, rhs in
                func area(_ frame: CGRect) -> CGFloat {
                    let overlap = frame.intersection(rect)
                    return overlap.isNull ? 0 : overlap.width * overlap.height
                }
                return area(lhs.frame) < area(rhs.frame)
            }
        }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let size = CGSize(width: Self.width, height: max(100, contentHeight))
        guard let frame = OverlayPlacement.frame(
            size: size, visibleFrame: screen.visibleFrame, anchor: anchor,
            composer: composer, protectedFrames: protectedFrames.isEmpty ? (anchor.map { [$0] } ?? []) : protectedFrames)
        else {
            // Never fall back to covering the conversation. Moving/resizing it will retry placement.
            panel.orderOut(nil)
            model?.overlayPlacementUnavailable = true
            return
        }
        model?.overlayPlacementUnavailable = false
        layout.width = frame.width
        layout.height = frame.height
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
