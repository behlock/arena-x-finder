import Foundation

public struct APIError: LocalizedError {
    public let status: Int
    public let retryAfter: Int?
    public var definiteRejection: Bool { [400, 401, 403, 404, 422, 429].contains(status) }
    public var errorDescription: String? {
        switch status {
        case 401: return "Your access token was rejected. Reconnect your Are.na account."
        case 403: return "Are.na denied access. Check that your token has write access and you can add to this channel."
        case 404: return "This channel or block is no longer available."
        case 429: return "Are.na’s rate limit was reached. Try again after \(retryAfter ?? 60) seconds."
        default: return "Are.na returned HTTP \(status). Your unfinished images remain queued."
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class ArenaClient {
    public typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let token: String
    private let transport: Transport
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    public init(token: String, transport: Transport? = nil) {
        self.token = token
        self.transport = transport ?? { request in
            let (data, response) = try await ArenaClient.session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw BridgeError.message("Invalid network response.") }
            return (data, response)
        }
    }

    public func me() async throws -> ArenaUser { try await request("me") }
    public func channels(userID: Int, page: Int = 1) async throws -> ChannelPage {
        try await request("users/\(userID)/contents?type=Channel&per=24&page=\(page)")
    }
    public func channel(_ input: String) async throws -> Channel {
        let slug = try Self.channelSlug(input)
        return try await request("channels/\(slug)")
    }
    public func block(_ id: Int) async throws -> ArenaBlock { try await request("blocks/\(id)") }

    public static func channelSlug(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug: String
        if value.contains("://") {
            guard let url = URL(string: value), url.scheme == "https",
                  ["www.are.na", "are.na"].contains(url.host ?? ""),
                  url.pathComponents.count == 3 else { throw BridgeError.message("Paste an Are.na channel URL or slug.") }
            slug = url.lastPathComponent
        } else { slug = value }
        guard !["channels", "contents"].contains(slug), slug.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw BridgeError.message("Paste a specific channel URL or slug, rather than your profile’s channels page.")
        }
        return slug
    }

    private struct Presign: Decodable {
        let files: [File]
        struct File: Decodable { let upload_url: URL; let key: String; let content_type: String }
    }
    public func upload(_ bytes: Data, filename: String, contentType: String) async throws -> URL {
        let result: Presign = try await request("uploads/presign", body: ["files": [["filename": filename, "content_type": contentType]]])
        guard let file = result.files.first, result.files.count == 1,
              file.upload_url.scheme == "https", file.content_type == contentType,
              let host = file.upload_url.host, host == "s3.amazonaws.com" || host.hasSuffix(".amazonaws.com"),
              file.key.hasPrefix("uploads/"), !file.key.split(separator: "/").contains("..") else {
            throw BridgeError.message("Are.na returned an invalid upload destination.")
        }
        var upload = URLRequest(url: file.upload_url)
        upload.httpMethod = "PUT"
        upload.setValue(contentType, forHTTPHeaderField: "Content-Type")
        upload.httpBody = bytes
        // Never send the Are.na bearer token to the storage provider.
        let (_, response) = try await transport(upload)
        guard (200..<300).contains(response.statusCode) else { throw BridgeError.message("Image upload failed (HTTP \(response.statusCode)). Try again.") }
        var url = URLComponents(string: "https://s3.amazonaws.com")!
        url.path = "/arena_images-temp/" + file.key
        return url.url!
    }

    public func createBlock(source: URL, title: String, channelID: Int) async throws -> ArenaBlock {
        try await request("blocks", body: ["value": source.absoluteString, "title": title, "channels": [["id": channelID]]])
    }

    private func request<T: Decodable>(_ path: String, body: [String: Any]? = nil) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.are.na/v3/" + path)!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw APIError(status: response.statusCode, retryAfter: seconds)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
