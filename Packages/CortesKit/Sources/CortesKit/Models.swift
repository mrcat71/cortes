import CoreGraphics
import Foundation

public enum ChatKind: String, Sendable, Codable {
    case channel
    case dm
}

public struct ConversationKey: Hashable, Sendable, Codable {
    public let app: String
    public let title: String

    public init(app: String, title: String) {
        self.app = app
        self.title = title
    }

    /// Stable string used for the cloud allowlist and the cooldown ledger.
    public var id: String { "\(app):\(title)" }
}

public struct ChatMessage: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var author: String
    public var text: String
    public var time: String?
    public var isMe: Bool

    public init(id: String, author: String, text: String, time: String? = nil, isMe: Bool = false) {
        self.id = id
        self.author = author
        self.text = text
        self.time = time
        self.isMe = isMe
    }
}

public struct ConversationSnapshot: Sendable {
    public var key: ConversationKey
    public var kind: ChatKind
    public var messages: [ChatMessage]
    public var myName: String?
    /// Area the overlay docks against, in AppKit global coordinates (bottom-left origin).
    public var anchorFrame: CGRect?
    public var capturedAt: Date

    public init(
        key: ConversationKey,
        kind: ChatKind,
        messages: [ChatMessage],
        myName: String?,
        anchorFrame: CGRect?,
        capturedAt: Date = Date()
    ) {
        self.key = key
        self.kind = kind
        self.messages = messages
        self.myName = myName
        self.anchorFrame = anchorFrame
        self.capturedAt = capturedAt
    }

    /// Changes when the tail of the conversation changes. Scrolling older history doesn't bump it.
    public var revision: String {
        guard let last = messages.last else { return "empty" }
        return "\(last.id)|\(Self.fnv1a(last.text))"
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

public enum CaptureEvent: Sendable {
    case snapshot(ConversationSnapshot)
    case inactive(String)
    case notTrusted
    case failed(String)
}
