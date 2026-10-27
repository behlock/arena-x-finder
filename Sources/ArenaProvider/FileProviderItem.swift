import FileProvider
import UniformTypeIdentifiers

public final class FileProviderItem: NSObject, NSFileProviderItem {
    public let record: ProviderRecord
    public init(_ record: ProviderRecord) { self.record = record }
    public var itemIdentifier: NSFileProviderItemIdentifier { Self.identifier(record.id) }
    public var parentItemIdentifier: NSFileProviderItemIdentifier { Self.identifier(record.parent) }
    public var filename: String { record.filename }
    public var contentType: UTType { UTType(record.typeIdentifier) ?? .data }
    public var documentSize: NSNumber? { record.size.map(NSNumber.init(value:)) }
    public var capabilities: NSFileProviderItemCapabilities {
        record.isFolder ? (record.writable ? [.allowsContentEnumerating, .allowsAddingSubItems] : [.allowsContentEnumerating]) : [.allowsReading]
    }
    public var contentPolicy: NSFileProviderContentPolicy { .downloadLazilyAndEvictOnRemoteUpdate }
    public var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data(record.version.utf8), metadataVersion: Data(record.fingerprint.utf8))
    }
    public static func identifier(_ value: String) -> NSFileProviderItemIdentifier {
        value == "root" ? .rootContainer : NSFileProviderItemIdentifier(value)
    }
    public static func key(_ identifier: NSFileProviderItemIdentifier) -> String {
        identifier == .rootContainer ? "root" : (identifier == .workingSet ? "working" : identifier.rawValue)
    }
}
