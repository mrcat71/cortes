import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("check-appcast: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else { fail("Usage: check-appcast.swift FEED ZIP INFO_PLIST") }
let feed = try XMLDocument(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let archiveURL = URL(fileURLWithPath: CommandLine.arguments[2])
let archive = try Data(contentsOf: archiveURL)
let plistData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
      let version = plist["CFBundleShortVersionString"] as? String,
      let build = plist["CFBundleVersion"] as? String,
      let keyText = plist["SUPublicEDKey"] as? String,
      let keyData = Data(base64Encoded: keyText),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else { fail("Bundle lacks valid version or update public key") }

let namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
let items = try feed.nodes(forXPath: "/rss/channel/item")
guard items.count == 1, let item = items.first as? XMLElement,
      let enclosure = item.elements(forName: "enclosure").first
else { fail("Expected exactly one update enclosure") }
let expectedURL = "https://github.com/mrcat71/cortes/releases/download/v\(version)/\(archiveURL.lastPathComponent)"
guard enclosure.attribute(forName: "url")?.stringValue == expectedURL,
      enclosure.attribute(forName: "length")?.stringValue == String(archive.count),
      item.elements(forLocalName: "version", uri: namespace).first?.stringValue == build,
      item.elements(forLocalName: "shortVersionString", uri: namespace).first?.stringValue == version
else { fail("Feed URL, archive length or versions do not match the bundle") }
guard let signatureText = enclosure.attribute(forLocalName: "edSignature", uri: namespace)?.stringValue,
      let signature = Data(base64Encoded: signatureText),
      key.isValidSignature(signature, for: archive)
else { fail("Archive signature does not match the bundle's SUPublicEDKey") }
print("Verified signed update for Cortes \(version)")
