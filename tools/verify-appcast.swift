import CryptoKit
import Foundation

// Validate against the public key shipped in Uso, not merely the key used by the signer.
do {
    guard CommandLine.arguments.count == 4 else {
        throw NSError(domain: "UsoAppcast", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: verify-appcast.swift Info.plist appcast.xml update.dmg"])
    }
    let metadataURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let feedURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let archiveURL = URL(fileURLWithPath: CommandLine.arguments[3])
    let metadata = try PropertyListSerialization.propertyList(from: Data(contentsOf: metadataURL), format: nil) as? [String: Any]
    let feed = try XMLDocument(data: Data(contentsOf: feedURL), options: [.nodeLoadExternalEntitiesNever])
    let items = try feed.nodes(forXPath: "/rss/channel/item")
    let archive = try Data(contentsOf: archiveURL)
    let namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    guard let version = metadata?["CFBundleShortVersionString"] as? String,
          let build = metadata?["CFBundleVersion"] as? String,
          let publicKeyText = metadata?["SUPublicEDKey"] as? String,
          let publicKeyData = Data(base64Encoded: publicKeyText),
          items.count == 1, let item = items.first,
          try item.nodes(forXPath: "sparkle:version").first?.stringValue == build,
          try item.nodes(forXPath: "sparkle:shortVersionString").first?.stringValue == version,
          let enclosure = try item.nodes(forXPath: "enclosure").first as? XMLElement,
          enclosure.attribute(forName: "url")?.stringValue == "https://github.com/0xIvan/uso/releases/download/v\(version)/\(archiveURL.lastPathComponent)",
          enclosure.attribute(forName: "length")?.stringValue == String(archive.count),
          let signatureText = enclosure.attribute(forLocalName: "edSignature", uri: namespace)?.stringValue,
          let signature = Data(base64Encoded: signatureText),
          try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData).isValidSignature(signature, for: archive) else {
        throw NSError(domain: "UsoAppcast", code: 2, userInfo: [NSLocalizedDescriptionKey: "Appcast metadata or update signature does not match Uso's Info.plist."])
    }
    print("Verified appcast metadata and update signature against Uso's public key.")
} catch {
    fputs("Appcast verification failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
