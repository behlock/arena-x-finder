import Foundation

@MainActor
public final class Uploader {
    public private(set) var isRunning = false
    public private(set) var status = ""
    public var onChange: (() -> Void)?
    private let store: Store
    public init(store: Store) { self.store = store }

    public func run(client: ArenaClient, accountID: Int, jobID: String? = nil) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; onChange?() }
        for job in store.jobs where jobID == nil || job.id == jobID {
            do {
                guard job.accountID == accountID else { throw BridgeError.message("Reconnect the account that owns this queued batch.") }
                try store.updateJob(job.id) { $0.lastError = nil }
                for (index, image) in job.images.enumerated() where !job.completed.contains(image.id) {
                    status = "Sending \(index + 1) of \(job.images.count) to \(job.destination.name)…"
                    onChange?()
                    let blockID: Int
                    if let known = job.blockIDs[image.id] { blockID = known }
                    else {
                        guard !job.creating.contains(image.id) else {
                            throw BridgeError.message("An upload was interrupted. Review the channel before retrying to avoid adding the image twice.")
                        }
                        let bytes = try store.imageData(jobID: job.id, image: image)
                        let filename = (image.name as NSString).deletingPathExtension + "." + image.fileExtension
                        let source = try await client.upload(bytes, filename: filename, contentType: image.contentType)
                        try store.updateJob(job.id) { $0.creating.insert(image.id) }
                        let block: ArenaBlock
                        do { block = try await client.createBlock(source: source, title: image.name, channelID: job.destination.channelID) }
                        catch {
                            if let error = error as? APIError, error.definiteRejection {
                                try store.updateJob(job.id) { $0.creating.remove(image.id) }
                            }
                            throw error
                        }
                        blockID = block.id
                        try store.updateJob(job.id) { $0.blockIDs[image.id] = block.id; $0.creating.remove(image.id) }
                    }
                    // Processing may finish later. Persist the block ID before polling;
                    // resuming checks that same block and never creates it again.
                    var available = false
                    for attempt in 0..<8 {
                        let block = try await client.block(blockID)
                        if block.state == "available" { available = true; break }
                        if block.state == "failed" { throw BridgeError.message("Are.na could not process \(image.name). Open the channel to review it; discard this batch before sending a replacement.") }
                        status = "Are.na is processing \(image.name)…"; onChange?()
                        if attempt < 7 { try await Task.sleep(nanoseconds: 3_000_000_000) }
                    }
                    guard available else { throw BridgeError.message("Are.na is still processing this image. Resume shortly to check its progress.") }
                    try store.acknowledge(jobID: job.id, imageID: image.id)
                    onChange?()
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                status = "Sent to \(job.destination.name)."
            } catch {
                status = error.localizedDescription
                try? store.updateJob(job.id) { $0.lastError = status }
                return
            }
        }
    }
}
