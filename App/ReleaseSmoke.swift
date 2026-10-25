import AppKit
import CortesKit
import SwiftUI

/// Verifies the shipped updater without starting capture, Ollama or the user's AppModel.
@MainActor
enum ReleaseSmoke {
    static func run() -> Never {
        if let problem = UpdateConfiguration.problem(bundleURL: Bundle.main.bundleURL, info: Bundle.main.infoDictionary ?? [:]) {
            fputs("Self-test failed: \(problem)\n", stderr)
            exit(1)
        }
        // Never schedule network checks or persist preference changes during a smoke test.
        UserDefaults.standard.setVolatileDomain([
            "SUEnableAutomaticChecks": false,
            "SUHasLaunchedBefore": true,
        ], forName: UserDefaults.argumentDomain)
        _ = NSApplication.shared
        AppUpdater.shared.start()
        if let problem = AppUpdater.shared.problem {
            fputs("Self-test failed: \(problem)\n", stderr)
            exit(1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            let view = NSHostingView(rootView: Form { UpdateSettings() }.formStyle(.grouped).frame(width: 620, height: 220))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                fputs("Self-test failed: cannot render update settings\n", stderr)
                exit(1)
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            do {
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            } catch {
                fputs("Self-test failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        print("Cortes updater self-test passed")
        exit(0)
    }
}
