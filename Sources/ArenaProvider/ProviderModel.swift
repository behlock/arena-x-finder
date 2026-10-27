import Foundation
import UniformTypeIdentifiers
import CryptoKit
import ArenaCore

public struct FinderChannel: Codable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let slug: String
    public let writable: Bool
    public init(id: Int, title: String, slug: String, writable: Bool) {
        self.id = id; self.title = title; self.slug = slug; self.writable = writable
    }
}

public struct FinderConfiguration: Codable, Sendable {
    public var accountID: Int
    public var channels: [FinderChannel]
    public var refreshGeneration: Int
    public init(accountID: Int, channels: [FinderChannel] = [], refreshGeneration: Int = 0) {
        self.accountID = accountID; self.channels = channels; self.refreshGeneration = refreshGeneration
    }
}

public enum ProviderPaths {
    public static var groupID: String? { Bundle.main.object(forInfoDictionaryKey: "ArenaAppGroup") as? String }
    public static func groupDirectory() throws -> URL {
        guard let groupID, let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw BridgeError.message("Build and install the signed Finder extension first.")
        }
        return url
    }
    public static func configurationURL() throws -> URL { try groupDirectory().appendingPathComponent("finder-configuration.json") }
    public static func configuration() throws -> FinderConfiguration {
        try JSONDecoder().decode(FinderConfiguration.self, from: Data(contentsOf: configurationURL()))
    }
    public static func saveConfiguration(_ configuration: FinderConfiguration) throws {
        let url = try configurationURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(configuration).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct ProviderRecord: Codable, Equatable, Sendable {
    public var id: String
    public var parent: String
    public var filename: String
    public var typeIdentifier: String
    public var channelID: Int?
    public var blockID: Int?
    public var page: Int?
    public var writable: Bool = false
    public var source: URL?
    public var thumbnail: URL?
    public var inlineData: Data?
    public var size: Int64?
    public var version: String = "1"
    public var websiteThumbnailRevision: String?
    public var websiteThumbnailDate: Date?
    public var nestedChannel: FinderChannel?
    // Identifies a channel occurrence independently of its pagination folders.
    public var namespace: String?
    public var websiteURL: URL? {
        guard typeIdentifier == "com.apple.web-internet-location", let inlineData,
              let value = try? PropertyListSerialization.propertyList(from: inlineData, format: nil) as? [String: String],
              let string = value["URL"], let url = URL(string: string), WebsiteThumbnailStore.valid(url) else { return nil }
        return url
    }
    public var contentVersion: Data {
        guard websiteURL != nil else { return Data(version.utf8) }
        // Publish preview changes as a new content version, alongside the date.
        let value = version + "\n" + (thumbnail?.absoluteString ?? "") + "\n" + (websiteThumbnailRevision ?? "pending")
        return Data(SHA256.hash(data: Data(value.utf8)))
    }
    public var isFolder: Bool { typeIdentifier == UTType.folder.identifier }
    public static func channel(_ channel: FinderChannel) -> ProviderRecord {
        ProviderRecord(id: "channel-\(channel.id)", parent: "root", filename: cleanName(channel.title) + " [\(channel.id)]",
                       typeIdentifier: UTType.folder.identifier, channelID: channel.id, page: 1, writable: channel.writable)
    }
    public static func more(channelID: Int, page: Int, parent: String, writable: Bool, channel: FinderChannel? = nil, namespace: String? = nil) -> ProviderRecord {
        var record = ProviderRecord(id: scopedID("page-\(channelID)-\(page)", namespace: namespace), parent: parent, filename: "More items (page \(page))",
                       typeIdentifier: UTType.folder.identifier, channelID: channelID, page: page, writable: writable)
        record.nestedChannel = channel
        record.namespace = namespace
        return record
    }
    public static func scopedID(_ id: String, namespace: String?) -> String {
        guard let namespace else { return id }
        return "occurrence-" + SHA256.hash(data: Data((namespace + "\n" + id).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func block(_ block: RemoteBlock, channelID: Int, parent: String) throws -> ProviderRecord {
        let title = cleanName(block.title ?? "Untitled")
        var record = ProviderRecord(id: "block-\(channelID)-\(block.id)", parent: parent, filename: title,
                                    typeIdentifier: UTType.data.identifier, channelID: channelID, blockID: block.id,
                                    version: block.updated_at ?? "1")
        let kind = block.type.lowercased()
        if kind == "channel" {
            record.id = "nested-\(channelID)-\(block.id)"
            record.typeIdentifier = UTType.folder.identifier
            record.filename = title + " [\(block.id)]"
            record.channelID = block.id
            record.page = 1
            record.writable = block.can?.add_to == true
            record.nestedChannel = FinderChannel(id: block.id, title: block.title ?? "Untitled", slug: block.slug ?? String(block.id), writable: record.writable)
        } else if kind == "image", let image = block.image, let source = image.src {
            record.source = source; record.thumbnail = image.small?.src; record.size = image.file_size
            record.typeIdentifier = image.content_type.flatMap { UTType(mimeType: $0)?.identifier } ?? UTType.image.identifier
            record.filename = fileName(title, id: block.id, ext: image.filename.map { ($0 as NSString).pathExtension } ?? source.pathExtension, fallback: "jpg")
        } else if kind == "attachment", let attachment = block.attachment {
            record.source = attachment.url; record.size = attachment.file_size
            record.typeIdentifier = attachment.content_type.flatMap { UTType(mimeType: $0)?.identifier } ?? UTType.data.identifier
            record.filename = fileName(title, id: block.id, ext: attachment.filename.map { ($0 as NSString).pathExtension } ?? attachment.url.pathExtension, fallback: "bin")
        } else if kind == "text" {
            record.inlineData = Data((block.content?.markdown ?? block.content?.plain ?? "").utf8)
            record.typeIdentifier = UTType.plainText.identifier
            record.filename = fileName(title, id: block.id, ext: "md", fallback: "md")
        } else {
            let source = block.source?.url
            let webURL = ["http", "https"].contains(source?.scheme?.lowercased() ?? "") ? source?.absoluteString : nil
            let url = kind == "channel" ? "https://www.are.na/channel/\(block.slug ?? String(block.id))"
                : webURL ?? "https://www.are.na/block/\(block.id)"
            record.inlineData = try PropertyListSerialization.data(fromPropertyList: ["URL": url], format: .xml, options: 0)
            record.typeIdentifier = "com.apple.web-internet-location"
            record.thumbnail = block.image?.small?.src
            record.filename = fileName(title, id: block.id, ext: "webloc", fallback: "webloc")
        }
        if let data = record.inlineData { record.size = Int64(data.count) }
        return record
    }
    public static func cleanName(_ name: String) -> String {
        let cleaned = name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || "/:".unicodeScalars.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var safe = String(cleaned.prefix(80))
        while safe.utf8.count > 160 { safe.removeLast() }
        return safe.isEmpty || safe == "." || safe == ".." ? "Untitled" : (safe.hasPrefix(".") ? "_" + safe : safe)
    }
    private static func fileName(_ title: String, id: Int, ext: String, fallback: String) -> String {
        let ext = ext.range(of: "^[A-Za-z0-9]{1,12}$", options: .regularExpression) != nil ? ext.lowercased() : fallback
        let stem = title.lowercased().hasSuffix("." + ext) ? String(title.dropLast(ext.count + 1)) : title
        return "\(stem) [\(id)].\(ext)"
    }
    public var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}
