import Foundation

// SwiftPM cannot condition resource copies on the Xcode configuration. Remove only
// the synthetic fixtures from the built release bundle, then the Makefile re-signs it.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: prepare-release.swift APP_PATH")
}
let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard app.lastPathComponent == "Cortes.app" else { fatalError("Expected Cortes.app") }
let scenarios = app.appendingPathComponent("Contents/Resources/CortesKit_CortesKit.bundle/Contents/Resources/Scenarios")
if FileManager.default.fileExists(atPath: scenarios.path) {
    try FileManager.default.removeItem(at: scenarios)
}
