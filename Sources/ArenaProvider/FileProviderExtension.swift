import FileProvider
import ArenaCore

@objc(ArenaFileProviderExtension)
public final class ArenaFileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing {
    private let engine: Result<ProviderEngine, Error>
    private let manager: NSFileProviderManager?
    public required init(domain: NSFileProviderDomain) {
        manager = NSFileProviderManager(for: domain)
        engine = Result {
            let group = try ProviderPaths.groupDirectory()
            let demo = domain.identifier.rawValue == "arena-demo"
            let directory = group.appendingPathComponent(demo ? "provider-demo" : "provider-live", isDirectory: true)
            let backend: any ProviderBackend
            if demo {
                backend = try DemoProviderBackend(directory: directory.appendingPathComponent("remote"))
                let token = try? CredentialVault.read(service: "com.behlock.arena-x-finder.smoke", interactive: false)
                try? JSONEncoder().encode(["sharedKeychainReadable": token == "local-smoke-value"]).write(to: group.appendingPathComponent("provider-smoke.json"), options: .atomic)
            } else {
                backend = LiveProviderBackend(credentials: {
                    guard let token = try CredentialVault.read(interactive: false), !token.isEmpty else { throw NSFileProviderError(.notAuthenticated) }
                    return token
                }, metricsURL: directory.appendingPathComponent("request-counts.json"))
            }
            return try ProviderEngine(directory: directory, backend: backend,
                websiteThumbnails: demo ? nil : WebsiteThumbnailStore(directory: group.appendingPathComponent("website-thumbnails"))) {
                demo ? FinderConfiguration(accountID: 0, channels: [DemoProviderBackend.channel]) : try ProviderPaths.configuration()
            }
        }
        super.init()
    }
    public func invalidate() {}
    static func error(_ error: Error) -> Error {
        if let api = error as? APIError {
            if api.status == 401 { return NSFileProviderError(.notAuthenticated) }
            if api.status == 404 { return NSFileProviderError(.noSuchItem) }
            if api.status == 429 { return NSFileProviderError(.serverUnreachable) }
        }
        if let failure = error as? ProviderFailure, case .missing = failure { return NSFileProviderError(.noSuchItem) }
        if error is CancellationError { return CocoaError(.userCancelled) }
        if error is URLError { return NSFileProviderError(.serverUnreachable) }
        if error is NSFileProviderError { return error }
        return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.cannotSynchronize.rawValue,
                       userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
    }
    public func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
                     completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let task = Task {
            do { let item = try await engine.get().item(FileProviderItem.key(identifier)); progress.completedUnitCount = 1; completionHandler(FileProviderItem(item), nil) }
            catch { completionHandler(nil, Self.error(error)) }
        }
        progress.cancellationHandler = { task.cancel() }; return progress
    }
    public func fetchContents(for identifier: NSFileProviderItemIdentifier, version: NSFileProviderItemVersion?, request: NSFileProviderRequest,
                              completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let task = Task {
            do {
                let (record, data) = try await engine.get().contents(FileProviderItem.key(identifier))
                let item = FileProviderItem(record)
                if let version, version.contentVersion != item.itemVersion.contentVersion { throw NSFileProviderError(.versionNoLongerAvailable) }
                try Task.checkCancellation()
                guard let manager else { throw ProviderFailure.missing }
                let url = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
                try data.write(to: url, options: .atomic)
                progress.completedUnitCount = 1; completionHandler(url, item, nil)
            } catch { completionHandler(nil, nil, Self.error(error)) }
        }
        progress.cancellationHandler = { task.cancel() }; return progress
    }
    public func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                           options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                           completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let task = Task {
            do {
                guard itemTemplate.contentType != .folder, itemTemplate.contentType != .symbolicLink else { throw ProviderFailure.readOnly }
                let record = try await engine.get().importFile(requestID: itemTemplate.itemIdentifier.rawValue,
                    parent: FileProviderItem.key(itemTemplate.parentItemIdentifier), filename: itemTemplate.filename, file: url)
                progress.completedUnitCount = 1
                completionHandler(FileProviderItem(record), [], false, nil)
                try? await manager?.signalEnumerator(for: .workingSet)
            } catch { completionHandler(nil, [], false, Self.error(error)) }
        }
        progress.cancellationHandler = { task.cancel() }; return progress
    }
    public func modifyItem(_ item: NSFileProviderItem, baseVersion: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                           contents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                           completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, CocoaError(.featureUnsupported)); return Progress()
    }
    public func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion: NSFileProviderItemVersion,
                           options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                           completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(CocoaError(.featureUnsupported)); return Progress()
    }
    public func enumerator(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if identifier == .trashContainer { throw CocoaError(.featureUnsupported) }
        return ProviderEnumerator(parent: FileProviderItem.key(identifier), engine: try engine.get(),
                                  manager: manager)
    }
    public func fetchThumbnails(for identifiers: [NSFileProviderItemIdentifier], requestedSize: CGSize,
                                perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
                                completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(identifiers.count))
        let task = Task {
            for id in identifiers {
                do { try Task.checkCancellation(); let data = try await engine.get().thumbnail(FileProviderItem.key(id)); perThumbnailCompletionHandler(id, data, nil) }
                catch { perThumbnailCompletionHandler(id, nil, Self.error(error)) }
                progress.completedUnitCount += 1
            }
            completionHandler(nil)
        }
        progress.cancellationHandler = { task.cancel() }; return progress
    }
}

final class ProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let parent: String
    private let engine: ProviderEngine
    init(parent: String, engine: ProviderEngine, manager: NSFileProviderManager?) {
        self.parent = parent; self.engine = engine
        super.init()
        if parent != "root" && parent != "working" {
            // Finder requests can arrive through system helpers without the file-viewer flag.
            // A cached directory may only get a subscription/currentSyncAnchor,
            // without enumerateItems. Refresh at subscription time as well.
            Task {
                do {
                    let changed = try await engine.refreshForBrowsing(parent)
                    if changed {
                        try await manager?.signalEnumerator(for: FileProviderItem.identifier(parent))
                        try await manager?.signalEnumerator(for: .workingSet)
                    }
                } catch { /* Preserve the last listing; a later open or manual refresh retries. */ }
            }
        }
    }
    // Finish an in-flight refresh and publish its changes even if Finder navigates away.
    func invalidate() {}
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                let items = try await engine.list(parent)
                observer.didEnumerate(items.map(FileProviderItem.init))
                observer.finishEnumerating(upTo: nil)
            } catch { observer.finishEnumeratingWithError(ArenaFileProviderExtension.error(error)) }
        }
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        Task {
            do {
                if parent == "working" { try await engine.refreshLoadedPages() }
                else { _ = try await engine.list(parent) }
                let revision = Int(String(data: anchor.rawValue, encoding: .utf8) ?? "0") ?? 0
                let changes = try await engine.changes(after: revision, parent: parent == "working" ? nil : parent)
                observer.didUpdate(changes.updated.filter { parent == "working" || $0.parent == parent }.map(FileProviderItem.init))
                observer.didDeleteItems(withIdentifiers: changes.deleted.map(FileProviderItem.identifier))
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(Data(String(changes.revision).utf8)), moreComing: false)
            } catch { observer.finishEnumeratingWithError(ArenaFileProviderExtension.error(error)) }
        }
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task { completionHandler(NSFileProviderSyncAnchor(Data(String(await engine.revision()).utf8))) }
    }
}
