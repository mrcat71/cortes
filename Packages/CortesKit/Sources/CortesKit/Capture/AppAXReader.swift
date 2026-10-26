import AppKit
import ApplicationServices

/// Best-effort context, not a chat parser. Called only for applications the user explicitly enabled.
final class AppAXReader {
    func read(application: NSRunningApplication, scope: AppTextScope) throws -> ConversationSnapshot {
        guard AXIsProcessTrusted() else { throw SlackAXReader.ReadError.notTrusted }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)
        // Electron applications expose their web content only after this opt-in flag.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let windowValue = AX.attribute(app, kAXFocusedWindowAttribute) else {
            throw LLMError.unavailable("No focused window in this app.")
        }
        let window = windowValue as! AXUIElement
        let title = AX.string(window, kAXTitleAttribute) ?? application.localizedName ?? "Application"
        var text = ""
        var composer: CGRect?
        if let focusedValue = AX.attribute(app, kAXFocusedUIElementAttribute) {
            let focused = focusedValue as! AXUIElement
            if !isProtected(focused) {
                text = AX.string(focused, kAXSelectedTextAttribute) ?? ""
                composer = AX.frame(focused).map(AX.appKitRect)
            }
        }
        if text.isEmpty, scope == .visibleWindow { text = visibleText(in: window) }
        guard
            var snapshot = AppTextContext.snapshot(
                appID: application.bundleIdentifier ?? "pid:\(application.processIdentifier)", title: title, text: text,
                scope: scope)
        else {
            throw LLMError.unavailable(
                scope == .selection
                    ? "Select text in this app, then ask the voices."
                    : "This window doesn't expose readable text through Accessibility.")
        }
        snapshot.anchorFrame = AX.frame(window).map(AX.appKitRect)
        snapshot.composerFrame = composer
        snapshot.protectedFrames = snapshot.anchorFrame.map { [$0] } ?? []
        return snapshot
    }

    private func isProtected(_ element: AXUIElement) -> Bool {
        AX.string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
            || AX.role(element) == "AXSecureTextField"
            || AX.attribute(element, "AXProtectedContent") as? Bool == true
    }

    private func visibleText(in root: AXUIElement) -> String {
        var stack = [(root, 0)]
        var pieces: [String] = []
        var visited = 0
        var remaining = 6000
        let deadline = Date().addingTimeInterval(0.5)
        let windowFrame = AX.frame(root)
        while let (element, depth) = stack.popLast(), visited < 1200, remaining > 0, Date() < deadline {
            visited += 1
            guard !isProtected(element), AX.attribute(element, "AXHidden") as? Bool != true else { continue }
            if let frame = AX.frame(element), let windowFrame, !frame.intersects(windowFrame) { continue }
            let role = AX.role(element)
            // Do not copy editable drafts, search fields or password controls into visible-window context.
            if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) { continue }
            if role == kAXStaticTextRole, let value = AX.string(element, kAXValueAttribute), !value.isEmpty {
                let piece = String(value.prefix(remaining))
                pieces.append(piece)
                remaining -= piece.count
            } else if depth < 35 {
                for child in AX.children(element).prefix(1200).reversed() { stack.append((child, depth + 1)) }
            }
        }
        return pieces.joined(separator: "\n")
    }
}
