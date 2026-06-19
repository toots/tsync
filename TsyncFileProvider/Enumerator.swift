import FileProvider
import OSLog

private let log = Logger(subsystem: "com.toots.tsync", category: "Enumerator")

final class TsyncEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let store: S3Store
    private let startupAnchor: NSFileProviderSyncAnchor

    init(containerIdentifier: NSFileProviderItemIdentifier, store: S3Store, startupAnchor: NSFileProviderSyncAnchor) {
        self.containerIdentifier = containerIdentifier
        self.store = store
        self.startupAnchor = startupAnchor
    }

    func invalidate() {}

    func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                if containerIdentifier == .workingSet {
                    try await enumerateWorkingSet(observer: observer)
                    return
                }

                let prefix = containerIdentifier == .rootContainer
                    ? store.domainPrefix
                    : containerIdentifier.rawValue

                let (subPrefixes, fileKeys) = try await store.listDirectory(prefix: prefix)
                var items: [TsyncItem] = []

                for folderPrefix in subPrefixes {
                    items.append(TsyncItem(
                        identifier: NSFileProviderItemIdentifier(folderPrefix),
                        parent: containerIdentifier,
                        filename: store.name(of: folderPrefix),
                        isDirectory: true
                    ))
                }
                for key in fileKeys {
                    items.append(TsyncItem(
                        identifier: NSFileProviderItemIdentifier(key),
                        parent: containerIdentifier,
                        filename: store.name(of: key),
                        isDirectory: false
                    ))
                }

                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // Expire anchor on every restart so FP re-enumerates all containers via enumerateItems,
        // ensuring full consistency with S3 state including deletions.
        // ponytail: upgrade path: S3 event notifications via SNS/SQS for incremental changes
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(startupAnchor)
    }

    // MARK: - Private

    private func enumerateWorkingSet(observer: any NSFileProviderEnumerationObserver) async throws {
        log.info("enumerateItems: working set full scan")
        let objects = try await store.client.listWithMetadata(prefix: store.domainPrefix)
        let items = objects.map { obj -> TsyncItem in
            let parent = TsyncItem.parentIdentifier(for: obj.key, domainPrefix: store.domainPrefix)
            let name = store.name(of: obj.key)
            return obj.key.hasSuffix("/")
                ? TsyncItem(identifier: .init(obj.key), parent: parent, filename: name, isDirectory: true)
                : TsyncItem(identifier: .init(obj.key), parent: parent, filename: name, isDirectory: false,
                            size: obj.size, modificationDate: obj.modified, etag: obj.etag)
        }
        log.info("enumerateItems: working set found \(items.count, privacy: .public) items")
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
    }
}
