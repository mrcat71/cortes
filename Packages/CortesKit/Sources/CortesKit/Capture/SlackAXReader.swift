import AppKit
import ApplicationServices
import Foundation

/// Reads the visible Slack conversation through the Accessibility tree.
///
/// Verified on Slack 4.51 / Electron 43 (docs/poc-results.md): after `AXManualAccessibility` is set, the
/// message list is an `AXList` inside `.p-message_pane`; every message is a `.c-virtual_list__item` whose
/// DOM id is `message-list_<ts>`, with `.c-message__sender_button`, `.c-timestamp` and rich-text blocks.
/// Not thread-safe: use it from one serial queue.
public final class SlackAXReader: @unchecked Sendable {
    public static let bundleID = "com.tinyspeck.slackmacgap"

    public enum ReadError: LocalizedError {
        case notRunning
        case notTrusted
        case noWindow
        case noMessageList

        public var errorDescription: String? {
            switch self {
            case .notRunning: "Slack isn't running"
            case .notTrusted: "Accessibility permission is missing"
            case .noWindow: "No Slack window"
            case .noMessageList: "No conversation open in Slack"
            }
        }
    }

    private var pid: pid_t = 0
    private var app: AXUIElement?
    private var detectedMyName: String?

    public init() {}

    public static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    public static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces)
            .compare(b.trimmingCharacters(in: .whitespaces), options: [.caseInsensitive, .diacriticInsensitive])
            == .orderedSame
    }

    /// Reads a snapshot of the focused Slack window. `myNameOverride` beats detection; `myNameFallback`
    /// (the last name detected in an earlier run) is used when the sidebar's "you" row isn't rendered.
    public func read(
        myNameOverride: String? = nil, myNameFallback: String? = nil, maxMessages: Int = 30
    ) throws -> ConversationSnapshot {
        guard AXIsProcessTrusted() else { throw ReadError.notTrusted }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            throw ReadError.notRunning
        }
        if running.processIdentifier != pid || app == nil {
            pid = running.processIdentifier
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.5)
            // Electron builds its AX tree only for clients that ask; this flag is the documented opt-in.
            // Never set AXEnhancedUserInterface: it breaks window managers and animations.
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            app = element
            detectedMyName = nil
        }
        guard let app else { throw ReadError.notRunning }

        let window =
            (AX.attribute(app, kAXFocusedWindowAttribute) as! AXUIElement?)
            ?? (AX.attribute(app, kAXMainWindowAttribute) as! AXUIElement?)
            ?? ((AX.attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first)
        guard let window else { throw ReadError.noWindow }

        func findLists() -> [AXUIElement] {
            AX.matching(in: window) { element in
                AX.role(element) == kAXListRole as String
                    && AX.children(element).contains { AX.domID($0).flatMap(Self.messageTimestamp) != nil }
            }
        }
        var lists = findLists()
        if lists.isEmpty {
            // Chromium drops its web accessibility tree when nobody has queried it for a while. Opt in
            // again and give it a moment to rebuild (about 1-2 s) before concluding nothing is open.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            for _ in 0..<8 where lists.isEmpty {
                Thread.sleep(forTimeInterval: 0.25)
                lists = findLists()
            }
        }
        guard !lists.isEmpty else { throw ReadError.noMessageList }
        let focused = AX.attribute(app, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
        let focusedAncestors = focused.map { AX.ancestors(of: $0) } ?? []
        let panes = lists.map { list in
            AX.ancestors(of: list).first { element in
                AX.classes(element).contains { ["p-message_pane", "p-thread_view", "p-threads_view__thread"].contains($0) }
            } ?? list
        }
        let threads = lists.map { list in
            AX.ancestors(of: list).contains { element in
                AX.classes(element).contains { $0.hasPrefix("p-thread_view") || $0.hasPrefix("p-threads_view__thread") }
            }
        }
        let selected = Self.targetIndex(
            frames: panes.map { AX.frame($0) }, threads: threads, focus: focused.flatMap(AX.frame),
            focusedIndex: panes.indices.first { index in
                focusedAncestors.contains { CFEqual($0, panes[index]) || CFEqual($0, lists[index]) }
            })
        let pane = panes[selected]
        let list = lists[selected]
        let isThread = threads[selected]
        let composers = AX.matching(in: window) { element in
            AX.role(element) == kAXTextAreaRole as String
                && AX.string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole
        }
        let composer = composers.first { candidate in
            AX.ancestors(of: candidate).contains { CFEqual($0, pane) }
        } ?? composers.filter { candidate in
            guard let frame = AX.frame(candidate), let paneFrame = AX.frame(pane) else { return false }
            return frame.midX >= paneFrame.minX && frame.midX <= paneFrame.maxX
        }.min { lhs, rhs in
            let bottom = AX.frame(list)?.maxY ?? 0
            return abs((AX.frame(lhs)?.minY ?? 0) - bottom) < abs((AX.frame(rhs)?.minY ?? 0) - bottom)
        }

        if detectedMyName == nil,
           let row = AX.first(in: window, withClass: "p-channel_sidebar__channel--im-you", maxDepth: 40)
        {
            detectedMyName = AX.children(row)
                .first { AX.role($0) == kAXStaticTextRole as String }
                .flatMap { AX.string($0, kAXValueAttribute) }?
                .trimmingCharacters(in: .whitespaces)
        }

        let header = AX.first(in: window, withClass: "p-view_header__big_button", maxDepth: 40) { _, classes in
            classes.contains("p-channel_sidebar") || classes.contains("p-message_pane")
        }
        let headerTitle = header.flatMap { button in
            AX.children(button).first { AX.role($0) == kAXStaticTextRole as String }
                .flatMap { AX.string($0, kAXValueAttribute) }
        }
        let isDM = header.map { AX.classes($0).contains { $0.hasSuffix("--dm") } } ?? false
        let title = [headerTitle, AX.string(list, kAXDescriptionAttribute), AX.string(window, kAXTitleAttribute)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Slack"

        var messages: [ChatMessage] = []
        var lastAuthor: String?
        for item in AX.children(list) {
            guard let id = AX.domID(item), let ts = Self.messageTimestamp(fromDOMID: id) else { continue }
            guard var parsed = Self.parseMessage(item) else { continue }
            if parsed.author.isEmpty {
                // A follow-up in a group: same author as the message above. Without one in view, the
                // author is unknown, and the message is dropped rather than invent a speaker.
                guard let lastAuthor else { continue }
                parsed.author = lastAuthor
            }
            lastAuthor = parsed.author
            parsed.id = ts
            if !parsed.text.isEmpty { messages.append(parsed) }
        }

        // ME: the override, else the sidebar's "you" row, else the last name seen. In a DM, whoever
        // isn't the person in the header is ME, which also works when the sidebar row isn't rendered.
        var myName = myNameOverride.flatMap { $0.isEmpty ? nil : $0 } ?? detectedMyName ?? myNameFallback
        if myName == nil, isDM, let other = headerTitle?.trimmingCharacters(in: .whitespaces) {
            myName = messages.first { !Self.sameName($0.author, other) }?.author
        }
        if let myName {
            for index in messages.indices {
                messages[index].isMe = Self.sameName(messages[index].author, myName)
            }
        }

        let anchor = (AX.frame(pane) ?? AX.frame(window)).map(AX.appKitRect(fromAX:))
        let rootID = isThread ? messages.first?.id : nil
        guard !isThread || rootID != nil else { throw ReadError.noMessageList }
        return ConversationSnapshot(
            key: ConversationKey(app: "slack", title: title, threadID: rootID),
            kind: isDM ? .dm : .channel,
            messages: Self.recentMessages(messages, limit: maxMessages, includeParent: isThread),
            myName: myName,
            anchorFrame: anchor,
            composerFrame: composer.flatMap(AX.frame).map(AX.appKitRect),
            protectedFrames: (panes + composers).compactMap(AX.frame).map(AX.appKitRect))
    }

    static func recentMessages(_ messages: [ChatMessage], limit: Int, includeParent: Bool) -> [ChatMessage] {
        guard limit > 0 else { return [] }
        guard includeParent, messages.count > limit, limit > 1, let parent = messages.first else {
            return Array(messages.suffix(limit))
        }
        return [parent] + messages.suffix(limit - 1)
    }

    static func targetIndex(frames: [CGRect?], threads: [Bool], focus: CGRect?, focusedIndex: Int?) -> Int {
        if let focusedIndex { return focusedIndex }
        if let focus, let index = frames.indices.filter({ frames[$0]?.contains(CGPoint(x: focus.midX, y: focus.midY)) == true })
            .min(by: { (frames[$0]!.width * frames[$0]!.height) < (frames[$1]!.width * frames[$1]!.height) }) {
            return index
        }
        return threads.firstIndex(of: true) ?? 0
    }

    static func messageList(in pane: AXUIElement) -> AXUIElement? {
        var stack = [(pane, 0)]
        while let (element, depth) = stack.popLast() {
            if AX.role(element) == kAXListRole as String,
               AX.children(element).contains(where: { AX.domID($0)?.hasPrefix("message-list_") == true })
            {
                return element
            }
            if depth < 6 { stack.append(contentsOf: AX.children(element).map { ($0, depth + 1) }) }
        }
        return nil
    }

    /// `message-list_1792673677.999169` → `1792673677.999169`. Day dividers and spacers return nil.
    static func messageTimestamp(fromDOMID id: String) -> String? {
        guard id.hasPrefix("message-list_") else { return nil }
        let ts = String(id.dropFirst("message-list_".count))
        let parts = ts.split(separator: ".")
        guard parts.count == 2, parts[0].count == 10, parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber)
        else { return nil }
        return ts
    }

    /// Subtrees that are UI chrome rather than message content.
    static let skippedClasses: Set<String> = [
        "c-message__sender_button", "c-timestamp", "c-message_kit__reaction_bar", "c-reaction_bar",
        "c-message__reply_bar", "c-message_actions__container", "p-message_pane_message__compact_timestamp",
        "c-message_kit__gutter", "c-avatar", "c-message__broadcast_preamble", "c-message__edited_label",
    ]
    static let skippedRoles: Set<String> = [
        kAXButtonRole as String, kAXPopUpButtonRole as String, kAXCheckBoxRole as String,
    ]

    static func parseMessage(_ item: AXUIElement) -> ChatMessage? {
        let sender = AX.first(in: item, withClass: "c-message__sender_button", maxDepth: 6)
        let author = sender.flatMap { AX.string($0, kAXTitleAttribute) ?? AX.string($0, kAXDescriptionAttribute) } ?? ""
        let timestamp = AX.first(in: item, withClass: "c-timestamp", maxDepth: 8)
        let time = timestamp.flatMap { link in
            AX.children(link).first.flatMap { AX.string($0, kAXValueAttribute) }
        }
        // Text blocks are the children of the actions container; fall back to the whole item.
        let container = AX.first(in: item, withClass: "c-message_kit__actions", maxDepth: 4) ?? item
        var blocks: [String] = []
        for child in AX.children(container) {
            var pieces: [String] = []
            collectText(child, into: &pieces, depth: 0)
            let block = pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !block.isEmpty else { continue }
            blocks.append(AX.classes(child).contains("c-mrkdwn__quote") ? "> " + block : block)
        }
        let text = stripEditedMarker(blocks.joined(separator: "\n"))
        return ChatMessage(id: "", author: author.trimmingCharacters(in: .whitespaces), text: text, time: time)
    }

    /// Slack appends a localized "(edited)" label as plain text, with no class to filter on.
    static let editedLabels: Set<String> = [
        "edited", "editado", "изменено", "отредактировано", "bearbeitet", "modifié", "modificato", "bewerkt",
        "edytowano", "redigerad", "düzenlendi", "編集済み", "已编辑", "편집됨",
    ]

    static func stripEditedMarker(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return trimmed }
        let label = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        guard editedLabels.contains(label.lowercased()) else { return trimmed }
        return String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func collectText(_ element: AXUIElement, into pieces: inout [String], depth: Int, inEmoji: Bool = false) {
        guard depth < 12 else { return }
        let classes = AX.classes(element)
        if classes.contains(where: skippedClasses.contains) { return }
        if classes.contains(where: { $0.hasSuffix("edited_label") }) { return } // "(edited)" in any locale
        let role = AX.role(element)
        if skippedRoles.contains(role) { return }
        if role == kAXStaticTextRole as String {
            if let value = AX.string(element, kAXValueAttribute) { pieces.append(value) }
            return
        }
        let emoji = inEmoji || classes.contains { $0.hasPrefix("c-emoji") }
        if role == kAXImageRole as String {
            // Inline emoji (`.c-emoji` on the image or its wrapper) carry their name in the description.
            // Other images are file previews, avatars or badges; a file's name is already a text node.
            if emoji, let name = AX.string(element, kAXDescriptionAttribute), !name.isEmpty {
                pieces.append(":\(name.lowercased().replacingOccurrences(of: " ", with: "_")):")
            }
            return
        }
        for child in AX.children(element) {
            collectText(child, into: &pieces, depth: depth + 1, inEmoji: emoji)
        }
    }
}
