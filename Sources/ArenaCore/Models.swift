import Foundation

public enum BridgeError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

public struct ArenaUser: Decodable, Sendable {
    public let id: Int
    public let name: String
    public let slug: String
}

public struct Channel: Decodable, Sendable {
    public let id: Int
    public let title: String
    public let slug: String
    public let can: Abilities?
    public struct Abilities: Decodable, Sendable { public let add_to: Bool }
    public var destination: Destination { Destination(channelID: id, name: title, slug: slug) }
}

public struct ChannelPage: Decodable, Sendable {
    public let data: [Channel]
    public let meta: Pagination
    public struct Pagination: Decodable, Sendable { public let next_page: Int? }
}

public struct Destination: Codable, Equatable, Sendable {
    public var id: String { String(channelID) }
    public let channelID: Int
    public var name: String
    public let slug: String
    public init(channelID: Int, name: String, slug: String) {
        self.channelID = channelID; self.name = name; self.slug = slug
    }
    public var url: URL { URL(string: "https://www.are.na/channel/\(slug)")! }
}

public struct QueuedImage: Codable, Sendable {
    public let id: String
    public let name: String
    public let format: String
    public let width: Int
    public let height: Int
    public var fileExtension: String { format == "jpeg" ? "jpg" : "png" }
    public var contentType: String { format == "jpeg" ? "image/jpeg" : "image/png" }
}

public struct Job: Codable, Sendable {
    public let id: String
    public let accountID: Int
    public let destination: Destination
    public let images: [QueuedImage]
    public var completed: Set<String> = []
    // Written before creating a block. An interrupted POST needs human review.
    public var creating: Set<String> = []
    public var blockIDs: [String: Int] = [:]
    public var lastError: String?
}

public struct EnqueueResult: Sendable {
    public let job: Job
    public let skipped: [String]
}

public struct ArenaBlock: Decodable, Sendable {
    public let id: Int
    public let state: String
}
