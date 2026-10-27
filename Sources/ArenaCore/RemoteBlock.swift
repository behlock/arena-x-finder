import Foundation

public struct BlockPage: Decodable {
    public let data: [RemoteBlock]
    public let meta: ChannelPage.Pagination
}

public struct RemoteBlock: Codable, Sendable {
    public let id: Int
    public let type: String
    public let title: String?
    public let state: String?
    public let updated_at: String?
    public let slug: String?
    public let image: Image?
    public let attachment: Attachment?
    public let content: Text?
    public let source: Source?
    public let can: Abilities?
    public struct Abilities: Codable, Sendable { public let add_to: Bool? }
    public struct Image: Codable, Sendable {
        public let src: URL?
        public let filename: String?
        public let content_type: String?
        public let file_size: Int64?
        public let small: Version?
        public struct Version: Codable, Sendable { public let src: URL? }
    }
    public struct Attachment: Codable, Sendable {
        public let url: URL
        public let filename: String?
        public let content_type: String?
        public let file_size: Int64?
    }
    public struct Text: Codable, Sendable { public let markdown: String?; public let plain: String? }
    public struct Source: Codable, Sendable { public let url: URL? }
}
