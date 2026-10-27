import Foundation

public final class Store {
    private struct State: Codable, Equatable {
        var destinations: [Destination] = []
        var accountID: Int?
        var lastDestinationID: String?
    }
    private let stateURL: URL
    private var state: State
    public var destinations: [Destination] { state.destinations }
    public var lastDestinationID: String? { state.lastDestinationID }

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        stateURL = directory.appendingPathComponent("channels.json")
        // Read the old catalog once; leave its retired upload ledger and files intact.
        let source = FileManager.default.fileExists(atPath: stateURL.path)
            ? stateURL : directory.appendingPathComponent("state.json")
        state = FileManager.default.fileExists(atPath: source.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: source)) : State()
    }

    public func setAccount(_ id: Int) throws {
        guard state.accountID != id else { return }
        try persist(State(accountID: id))
    }

    public func save(_ destination: Destination) throws { try save([destination]) }

    public func save(_ destinations: [Destination]) throws {
        var next = state
        for destination in destinations {
            guard destination.channelID > 0, !destination.name.isEmpty,
                  destination.slug.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                throw BridgeError.message("Invalid Are.na channel.")
            }
            if let index = next.destinations.firstIndex(where: { $0.id == destination.id }) {
                next.destinations[index] = destination
            } else { next.destinations.append(destination) }
        }
        try persist(next)
    }

    public func select(_ id: String) throws {
        guard state.lastDestinationID != id, state.destinations.contains(where: { $0.id == id }) else { return }
        var next = state
        next.lastDestinationID = id
        try persist(next)
    }

    private func persist(_ next: State) throws {
        guard next != state || !FileManager.default.fileExists(atPath: stateURL.path) else { return }
        try JSONEncoder().encode(next).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        state = next
    }
}
