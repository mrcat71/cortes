#if DEBUG
import AppKit
import CortesKit
import SwiftUI

/// Synthetic UI checks only: no capture, network requests, Keychain access or persistent preferences.
@MainActor
enum InteractionSmoke {
    nonisolated private final class MemoryDefaults: UserDefaults {
        private var values: [String: Any] = [:]
        private let lock = NSLock()
        override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
        override func string(forKey key: String) -> String? { object(forKey: key) as? String }
        override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
        override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
        override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    }

    static func run() -> Never {
        do {
            _ = NSApplication.shared
            guard let index = CommandLine.arguments.firstIndex(of: "--interaction-self-test"),
                  CommandLine.arguments.indices.contains(index + 1) else {
                throw LLMError.unavailable("Pass an output directory after --interaction-self-test")
            }
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (code, text) in [
                ("en", "Please check the deployment before we release this change to our customers."),
                ("ru", "Пожалуйста, проверь развертывание перед выпуском этого изменения для наших клиентов."),
                ("es", "Por favor, revisa el despliegue antes de publicar este cambio para nuestros clientes."),
            ] {
                let defaults = MemoryDefaults()
                let model = AppModel(defaults: defaults, readKeychain: false)
                model.run(ConversationSnapshot(
                    key: ConversationKey(app: "slack", title: "Release discussion", threadID: "1792673677.999169"),
                    kind: .channel, messages: [.init(id: "1", author: "Test participant", text: text)],
                    myName: nil, anchorFrame: nil), manual: true)
                try check(model.language.code == code, "Wrong detected UI language")
                try check(model.localized("Copy") == ["en": "Copy", "ru": "Копировать", "es": "Copiar"][code], "Missing bundled translation")
                try check(model.localized("100% complete") == "100% complete", "Status text must not be interpreted as a format string")
                if code == "ru" {
                    try check(InterfaceText.riskReason("risk 7 above 4 for a professional chat", locale: model.language.locale)
                        == "риск 7 выше 4 для разговора типа «рабочий»", "Risk diagnostics must follow the conversation language")
                }
                let layout = OverlayLayout()
                layout.height = 420
                try snapshot(OverlayView(model: model, layout: layout, onSizeChange: { _ in }),
                    size: CGSize(width: 380, height: 420), to: directory.appendingPathComponent("consent-\(code).png"))
                layout.width = 240
                try snapshot(OverlayView(model: model, layout: layout, onSizeChange: { _ in }),
                    size: CGSize(width: 240, height: 420), to: directory.appendingPathComponent("consent-compact-\(code).png"))
                try snapshot(GeneralSettings(model: model).environment(\.locale, model.language.locale),
                    size: CGSize(width: 620, height: 560), to: directory.appendingPathComponent("general-\(code).png"))
                try snapshot(PrivacySettings(model: model).environment(\.locale, model.language.locale),
                    size: CGSize(width: 620, height: 560), to: directory.appendingPathComponent("privacy-\(code).png"))
                model.engine = .replay
                model.demoReset()
                let key = model.current?.key ?? ConversationKey(app: "demo", title: "Synthetic conversation")
                model.run(ConversationSnapshot(key: key, kind: .channel,
                    messages: [.init(id: "1", author: "Test participant", text: text)], myName: nil, anchorFrame: nil), manual: true)
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    if case .result = model.phase { break }
                    if case .failure = model.phase { break }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                guard case .result = model.phase else { throw LLMError.unavailable("Synthetic replay did not finish") }
                layout.width = 380
                layout.height = 600
                try snapshot(OverlayView(model: model, layout: layout, onSizeChange: { _ in }),
                    size: CGSize(width: 380, height: 600), to: directory.appendingPathComponent("result-\(code).png"))
                layout.width = 240
                layout.height = 420
                try snapshot(OverlayView(model: model, layout: layout, onSizeChange: { _ in }),
                    size: CGSize(width: 240, height: 420), to: directory.appendingPathComponent("result-compact-\(code).png"))
                model.enableTextApp("com.example.Chat")
                model.enableTextApp("com.example.Chat")
                try check(model.enabledTextApps == ["com.example.Chat"], "App opt-in should be idempotent")
                try check(!model.isAllowed(.init(app: "com.example.Chat", title: "Private window")), "App opt-in must not grant blanket analysis")
                model.showMenuBarIcon = false
                try check(NSApp.activationPolicy() == .regular, "Hidden menu icon must leave Dock access")
                try check(AppUpdater.shared.backgroundActivationPolicy == .regular, "Updater completion must preserve hidden-icon Dock access")
                try check(defaults.object(forKey: "showMenuBarIcon") as? Bool == false, "Menu preference must be stored")
                model.showMenuBarIcon = true
                try check(NSApp.activationPolicy() == .accessory, "Visible menu icon should restore accessory mode")
            }
            print("Cortes interaction self-test passed; synthetic snapshots: \(directory.path)")
            exit(0)
        } catch {
            fputs("Interaction self-test failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw LLMError.unavailable(message) }
    }

    private static func snapshot<Content: View>(_ content: Content, size: CGSize, to url: URL) throws {
        let hosting = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw LLMError.unavailable("Cannot render synthetic UI")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw LLMError.unavailable("Cannot encode synthetic UI snapshot")
        }
        try png.write(to: url)
    }
}
#endif
