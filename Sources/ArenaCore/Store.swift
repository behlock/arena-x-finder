import Foundation

public final class Store {
    public static let maximumImagesPerBatch = 100
    private static let preparationQueue = DispatchQueue(label: "arena-finder.preparation", qos: .userInitiated)
    struct PreparedImage { let format: String; let width: Int; let height: Int }
    private struct State: Codable {
        var destinations: [Destination] = []
        var accountID: Int?
        var lastDestinationID: String?
        var jobs: [Job] = []
    }
    public let directory: URL
    private var state: State
    private var preparing = 0
    public var isPreparingImages: Bool { preparing > 0 }
    public var destinations: [Destination] { state.destinations }
    public var lastDestinationID: String? { state.lastDestinationID }
    public var accountID: Int? { state.accountID }
    public var jobs: [Job] { state.jobs }
    private var queueDirectory: URL { directory.appendingPathComponent("queue", isDirectory: true) }
    private var stateURL: URL { directory.appendingPathComponent("state.json") }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("state.json")
        state = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) : State()
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public func setAccount(_ id: Int) throws {
        guard state.accountID != id else { return }
        guard state.jobs.isEmpty else { throw BridgeError.message("Finish or discard queued images before switching accounts.") }
        var next = state
        next.accountID = id; next.destinations = []; next.lastDestinationID = nil
        try persist(next)
    }

    public func save(_ destination: Destination) throws {
        guard destination.channelID > 0, !destination.name.isEmpty,
              destination.slug.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw BridgeError.message("Invalid Are.na channel.")
        }
        var next = state
        if let index = next.destinations.firstIndex(where: { $0.id == destination.id }) {
            next.destinations[index] = destination
        } else { next.destinations.append(destination) }
        try persist(next)
    }

    @MainActor
    public func enqueue(_ urls: [URL], destination: Destination) async throws -> EnqueueResult {
        guard let accountID = state.accountID, state.destinations.contains(destination),
              !urls.isEmpty, urls.count <= Self.maximumImagesPerBatch else {
            throw BridgeError.message("Connect your account, choose a channel, and select 1–100 images.")
        }
        preparing += 1
        defer { preparing -= 1 }
        let folder = queueDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let result: EnqueueResult = try await withCheckedThrowingContinuation { continuation in
            Self.preparationQueue.async {
                continuation.resume(with: Result {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    var images: [QueuedImage] = []; var skipped: [String] = []
                    for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                        do {
                            let id = UUID().uuidString
                            let image = try autoreleasepool { try Self.prepareImage(url, to: folder.appendingPathComponent(id)) }
                            images.append(QueuedImage(id: id, name: url.lastPathComponent, format: image.format, width: image.width, height: image.height))
                        } catch { skipped.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                    }
                    guard !images.isEmpty else {
                        try? FileManager.default.removeItem(at: folder)
                        throw BridgeError.message(skipped.joined(separator: "\n"))
                    }
                    return EnqueueResult(job: Job(id: folder.lastPathComponent, accountID: accountID, destination: destination, images: images), skipped: skipped)
                })
            }
        }
        do {
            var next = state
            next.jobs.append(result.job); next.lastDestinationID = destination.id
            try persist(next)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
        return result
    }

    public func imageData(jobID: String, image: QueuedImage) throws -> Data {
        guard state.jobs.contains(where: { $0.id == jobID && $0.images.contains(where: { $0.id == image.id }) }) else {
            throw BridgeError.message("Queued image not found.")
        }
        return try Data(contentsOf: queueDirectory.appendingPathComponent(jobID).appendingPathComponent(image.id + "." + image.fileExtension))
    }

    public func updateJob(_ id: String, _ update: (inout Job) -> Void) throws {
        guard let index = state.jobs.firstIndex(where: { $0.id == id }) else { throw BridgeError.message("Queued batch not found.") }
        var next = state
        update(&next.jobs[index])
        try persist(next)
    }

    public func acknowledge(jobID: String, imageID: String) throws {
        try updateJob(jobID) { job in
            job.completed.insert(imageID); job.creating.remove(imageID); job.lastError = nil
        }
        if let job = state.jobs.first(where: { $0.id == jobID }), job.completed.count == job.images.count {
            try discard(jobID: jobID)
        }
    }

    public func discard(jobID: String) throws {
        guard state.jobs.contains(where: { $0.id == jobID }) else { return }
        var next = state
        next.jobs.removeAll { $0.id == jobID }
        try persist(next)
        try? FileManager.default.removeItem(at: queueDirectory.appendingPathComponent(jobID))
    }

    private func persist(_ next: State) throws {
        try JSONEncoder().encode(next).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        state = next
    }
}
