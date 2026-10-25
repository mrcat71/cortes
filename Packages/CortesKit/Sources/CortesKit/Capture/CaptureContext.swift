import Foundation

public enum AppTextScope: String, CaseIterable, Sendable, Identifiable {
    case selection
    case visibleWindow
    public var id: String { rawValue }
    public var title: String { self == .selection ? "Selected text only" : "Visible window text" }
}

public enum CapturePrivacy {
    public static func allowsTextContext(_ snapshot: ConversationSnapshot, apps: [String], scope: AppTextScope) -> Bool
    {
        snapshot.kind != .context || (apps.contains(snapshot.key.app) && snapshot.textScope == scope)
    }

    public static func isLoopback(_ address: String) -> Bool {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host?.lowercased()
        else { return false }
        return ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
    }

    public static func matchesAudioApp(processBundleID: String, selectedBundleID: String) -> Bool {
        !selectedBundleID.isEmpty
            && (processBundleID == selectedBundleID
                || processBundleID.hasPrefix(selectedBundleID + "."))
    }
}

public enum AppTextContext {
    public static func snapshot(appID: String, title: String, text: String, scope: AppTextScope = .selection)
        -> ConversationSnapshot?
    {
        let cleaned = String(Sanitizer.clean(text, maxLength: 5999).prefix(6000)).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return ConversationSnapshot(
            key: ConversationKey(app: appID, title: Sanitizer.clean(title, maxLength: 120)), kind: .context,
            messages: [ChatMessage(id: "visible-text", author: "Unattributed app text", text: cleaned)],
            myName: nil, anchorFrame: nil, textScope: scope)
    }
}

/// Final utterances only, bounded in memory. Remote participants are deliberately not diarized.
public struct CallTranscript: Sendable {
    public let key: ConversationKey
    public private(set) var messages: [ChatMessage] = []
    private var sequence = 0

    public init(sessionID: UUID = UUID(), appName: String) {
        key = ConversationKey(app: "call:" + sessionID.uuidString, title: "Call: " + appName)
    }

    public mutating func append(_ text: String, isMe: Bool) {
        let cleaned = String(Sanitizer.clean(text, maxLength: 1199).prefix(1200)).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        sequence += 1
        messages.append(
            ChatMessage(
                id: String(sequence), author: isMe ? "ME" : "Call participants", text: cleaned, isMe: isMe))
        messages = Array(messages.suffix(40))
    }

    public var snapshot: ConversationSnapshot {
        ConversationSnapshot(key: key, kind: .call, messages: messages, myName: "ME", anchorFrame: nil)
    }
}
