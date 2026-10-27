import Foundation
import CryptoKit

/// Shares preview requests between the sandboxed provider and the renderer.
public struct WebsiteThumbnailStore {
    public struct Request: Codable {
        public let url: URL
    }
    public struct Result: Codable {
        public let completedAt: Date
        public let revision: String?
        public let failed: Bool
    }
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public static func valid(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") &&
        !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
    }
    public static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(("website-preview-v1\n" + url.absoluteString).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func path(_ url: URL, _ suffix: String) -> URL {
        directory.appendingPathComponent(Self.key(url) + suffix)
    }
    public func result(for url: URL) -> Result? {
        guard let data = try? Data(contentsOf: path(url, ".result")) else { return nil }
        return try? JSONDecoder().decode(Result.self, from: data)
    }
    public func image(for url: URL) -> Data? {
        guard result(for: url)?.revision != nil else { return nil }
        return try? Data(contentsOf: path(url, ".png"))
    }
    public func enqueue(_ url: URL, now: Date = Date()) throws {
        guard Self.valid(url) else { return }
        if let result = result(for: url), now.timeIntervalSince(result.completedAt) < (result.failed ? 24 * 3600 : 7 * 24 * 3600) { return }
        let request = path(url, ".request")
        guard !FileManager.default.fileExists(atPath: request.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Request(url: url)).write(to: request, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.path)
    }
    public func pending() throws -> [Request] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "request" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file in
                guard let data = try? Data(contentsOf: file), data.count < 64 * 1024,
                      let request = try? JSONDecoder().decode(Request.self, from: data), Self.valid(request.url),
                      file.deletingPathExtension().lastPathComponent == Self.key(request.url) else { return nil }
                return request
            }
    }
    public func complete(_ url: URL, png: Data?) throws {
        let previous = result(for: url)
        var revision = previous?.revision
        if let png {
            try png.write(to: path(url, ".png"), options: .atomic)
            revision = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        }
        let result = Result(completedAt: Date(), revision: revision, failed: png == nil)
        try JSONEncoder().encode(result).write(to: path(url, ".result"), options: .atomic)
        try? FileManager.default.removeItem(at: path(url, ".request"))
    }
}
