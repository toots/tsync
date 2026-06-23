import FileProvider
import Foundation
import OSLog

private let log = Logger(subsystem: "com.toots.tsync", category: "Extension")

final class TsyncExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    let domain: NSFileProviderDomain

    // Per-process sync anchor — changes each launch so FP calls enumerateChanges on startup.
    private static let startupAnchor = NSFileProviderSyncAnchor(
        "\(Date().timeIntervalSinceReferenceDate)".data(using: .utf8)!
    )

    // Lazy-initialized via setupTask; every method awaits this before using the store.
    private let setupTask: Task<S3Store, Error>

    required init(domain: NSFileProviderDomain) {
        log.info("init: domain=\(domain.identifier.rawValue, privacy: .public) version=1")
        self.domain = domain
        let displayName = domain.displayName
        self.setupTask = Task {
            do {
                let config = try Config.load()
                let credentials = try KeychainCredentials.load()
                let client = S3Client(bucket: config.bucket, region: config.awsRegion, credentials: credentials)
                return S3Store(client: client, config: config, domainName: displayName)
            } catch {
                log.error("setup failed: \(error, privacy: .public)")
                throw error
            }
        }
        super.init()
    }

    func invalidate() {
        log.info("invalidate: domain=\(self.domain.identifier.rawValue, privacy: .public)")
        setupTask.cancel()
        Task { try? (await setup()).client.shutdown() }
    }

    // MARK: - NSFileProviderReplicatedExtension

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let store = try await setup()
                let item = try await resolveItem(identifier: identifier, store: store)
                completionHandler(item, nil)
            } catch {
                completionHandler(nil, fpError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        Task {
            do {
                let store = try await setup()
                let key = itemIdentifier.rawValue
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                try await store.download(key: key, to: tmpURL)
                let item = try await resolveItem(identifier: itemIdentifier, store: store, isDownloaded: true)
                progress.completedUnitCount = 100
                completionHandler(tmpURL, item, nil)
            } catch {
                completionHandler(nil, nil, error)
            }
        }
        return progress
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        Task {
            do {
                let store = try await setup()
                let key = s3Key(for: itemTemplate, store: store)
                let isDirectory = itemTemplate.contentType == .folder
                log.info("createItem: key=\(key, privacy: .public) parent=\(itemTemplate.parentItemIdentifier.rawValue, privacy: .public) filename=\(itemTemplate.filename, privacy: .public)")

                if isDirectory {
                    let dirKey = store.directoryKey(key)
                    let relKey = store.relativePath(of: dirKey)
                    let journalKey = Journal.entryKey()
                    let ops = [JournalOp(op: "mkdir", key: relKey)]
                    Journal.writeLocalPending(ops: ops, entryKey: journalKey)
                    try await store.createDirectory(key: key)
                    Task {
                        await store.writeJournal(ops: ops, entryKey: journalKey)
                        Journal.deleteLocalPending(entryKey: journalKey)
                    }
                    let item = TsyncItem(
                        identifier: NSFileProviderItemIdentifier(dirKey),
                        parent: itemTemplate.parentItemIdentifier,
                        filename: itemTemplate.filename,
                        isDirectory: true
                    )
                    progress.completedUnitCount = 100
                    completionHandler(item, [], false, nil)
                } else {
                    let relKey = store.relativePath(of: key)
                    let journalKey = Journal.entryKey()
                    Journal.writeLocalPending(ops: [JournalOp(op: "put", key: relKey)], entryKey: journalKey)
                    if let contentURL = url {
                        try await store.upload(key: key, from: contentURL)
                    }
                    let (size, modified, etag) = try await store.head(key: key)
                    let ops = [JournalOp(op: "put", key: relKey, size: size)]
                    Task {
                        await store.writeJournal(ops: ops, entryKey: journalKey)
                        Journal.deleteLocalPending(entryKey: journalKey)
                    }
                    let item = TsyncItem(
                        identifier: NSFileProviderItemIdentifier(key),
                        parent: itemTemplate.parentItemIdentifier,
                        filename: itemTemplate.filename,
                        isDirectory: false,
                        size: size,
                        modificationDate: modified,
                        etag: etag,
                        isDownloaded: url != nil
                    )
                    progress.completedUnitCount = 100
                    completionHandler(item, [], false, nil)
                }
            } catch {
                completionHandler(nil, [], false, error)
            }
        }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        Task {
            do {
                let store = try await setup()
                let oldKey = item.itemIdentifier.rawValue
                let newKey = s3Key(for: item, store: store)
                let isRename = changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier)
                log.info("modifyItem: oldKey=\(oldKey, privacy: .public) newKey=\(newKey, privacy: .public) isRename=\(isRename) changedFields=\(changedFields.rawValue, privacy: .public)")

                if item.contentType == .folder {
                    if isRename && oldKey != newKey {
                        let oldDirKey = store.directoryKey(oldKey)
                        let newDirKey = store.directoryKey(newKey)
                        let ops = [JournalOp(op: "rename", key: store.relativePath(of: newDirKey), src: store.relativePath(of: oldDirKey))]
                        let journalKey = Journal.entryKey()
                        Journal.writeLocalPending(ops: ops, entryKey: journalKey)
                        try await store.renameDirectory(from: oldDirKey, to: newDirKey)
                        Task {
                            await store.writeJournal(ops: ops, entryKey: journalKey)
                            Journal.deleteLocalPending(entryKey: journalKey)
                        }
                    }
                    progress.completedUnitCount = 100
                    completionHandler(TsyncItem(
                        identifier: NSFileProviderItemIdentifier(store.directoryKey(newKey)),
                        parent: item.parentItemIdentifier,
                        filename: item.filename,
                        isDirectory: true
                    ), [], false, nil)
                    return
                }

                let journalKey = Journal.entryKey()
                if isRename && oldKey != newKey {
                    if let contentURL = newContents, changedFields.contains(.contents) {
                        let ops = [JournalOp(op: "rename", key: store.relativePath(of: newKey), src: store.relativePath(of: oldKey))]
                        Journal.writeLocalPending(ops: ops, entryKey: journalKey)
                        try await store.upload(key: newKey, from: contentURL)
                    } else {
                        let ops = [JournalOp(op: "rename", key: store.relativePath(of: newKey), src: store.relativePath(of: oldKey))]
                        Journal.writeLocalPending(ops: ops, entryKey: journalKey)
                        try await store.copy(from: oldKey, to: newKey)
                    }
                    try await store.delete(key: oldKey)
                } else if let contentURL = newContents, changedFields.contains(.contents) {
                    let ops = [JournalOp(op: "put", key: store.relativePath(of: newKey))]
                    Journal.writeLocalPending(ops: ops, entryKey: journalKey)
                    try await store.upload(key: newKey, from: contentURL)
                }

                let (size, modified, etag) = try await store.head(key: newKey)
                if isRename && oldKey != newKey {
                    let ops = [JournalOp(op: "rename", key: store.relativePath(of: newKey), src: store.relativePath(of: oldKey), size: size)]
                    Task {
                        await store.writeJournal(ops: ops, entryKey: journalKey)
                        Journal.deleteLocalPending(entryKey: journalKey)
                    }
                } else if changedFields.contains(.contents) {
                    let ops = [JournalOp(op: "put", key: store.relativePath(of: newKey), size: size)]
                    Task {
                        await store.writeJournal(ops: ops, entryKey: journalKey)
                        Journal.deleteLocalPending(entryKey: journalKey)
                    }
                }
                let updatedItem = TsyncItem(
                    identifier: NSFileProviderItemIdentifier(newKey),
                    parent: item.parentItemIdentifier,
                    filename: item.filename,
                    isDirectory: false,
                    size: size,
                    modificationDate: modified,
                    etag: etag,
                    isDownloaded: true
                )
                progress.completedUnitCount = 100
                completionHandler(updatedItem, [], false, nil)
            } catch {
                log.error("modifyItem error: \(error, privacy: .public)")
                completionHandler(nil, [], false, error)
            }
        }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let store = try await setup()
                let key = identifier.rawValue
                log.info("deleteItem: key=\(key, privacy: .public)")
                let opName = store.isDirectoryKey(key) ? "rmdir" : "delete"
                let ops = [JournalOp(op: opName, key: store.relativePath(of: key))]
                let journalKey = Journal.entryKey()
                Journal.writeLocalPending(ops: ops, entryKey: journalKey)
                try await store.delete(key: key)
                Task {
                    await store.writeJournal(ops: ops, entryKey: journalKey)
                    Journal.deleteLocalPending(entryKey: journalKey)
                }
                progress.completedUnitCount = 1
                completionHandler(nil)
            } catch {
                completionHandler(fpError(error))
            }
        }
        return progress
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        return LazyEnumerator(
            containerIdentifier: containerItemIdentifier,
            setupTask: setupTask,
            startupAnchor: TsyncExtension.startupAnchor
        )
    }

    // MARK: - Helpers

    private func setup() async throws -> S3Store {
        try await setupTask.value
    }

    /// FileProvider only accepts NSCocoaErrorDomain or NSFileProviderErrorDomain.
    private func fpError(_ error: Error) -> Error {
        let ns = error as NSError
        guard ns.domain != NSCocoaErrorDomain && ns.domain != NSFileProviderErrorDomain else { return error }
        return NSFileProviderError(.serverUnreachable)
    }

    private func resolveItem(
        identifier: NSFileProviderItemIdentifier,
        store: S3Store,
        isDownloaded: Bool = false
    ) async throws -> TsyncItem {
        if identifier == .rootContainer {
            return TsyncItem.rootContainer(displayName: domain.displayName)
        }

        let key = identifier.rawValue

        if key.hasSuffix("/") {
            let name = store.name(of: key)
            let parent = TsyncItem.parentIdentifier(for: key.dropLastComponent(), domainPrefix: store.domainPrefix)
            return TsyncItem(identifier: identifier, parent: parent, filename: name, isDirectory: true)
        }

        let (size, modified, etag) = try await store.head(key: key)
        let name = key.components(separatedBy: "/").last ?? key
        let parent = TsyncItem.parentIdentifier(for: key, domainPrefix: store.domainPrefix)
        return TsyncItem(
            identifier: identifier, parent: parent, filename: name,
            isDirectory: false, size: size, modificationDate: modified, etag: etag,
            isDownloaded: isDownloaded
        )
    }

    private func s3Key(for item: NSFileProviderItem, store: S3Store) -> String {
        if item.parentItemIdentifier == .rootContainer {
            return store.key(for: item.filename)
        }
        return "\(item.parentItemIdentifier.rawValue)\(item.filename)"
    }
}

// MARK: - LazyEnumerator

/// Wraps TsyncEnumerator, deferring s3 setup until enumerateItems is called.
final class LazyEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let setupTask: Task<S3Store, Error>
    private let startupAnchor: NSFileProviderSyncAnchor

    init(
        containerIdentifier: NSFileProviderItemIdentifier,
        setupTask: Task<S3Store, Error>,
        startupAnchor: NSFileProviderSyncAnchor
    ) {
        self.containerIdentifier = containerIdentifier
        self.setupTask = setupTask
        self.startupAnchor = startupAnchor
    }

    func invalidate() {}

    func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                let store = try await setupTask.value
                let inner = TsyncEnumerator(containerIdentifier: containerIdentifier, store: store, startupAnchor: startupAnchor)
                inner.enumerateItems(for: observer, startingAt: page)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        Task {
            do {
                let store = try await setupTask.value
                let inner = TsyncEnumerator(containerIdentifier: containerIdentifier, store: store, startupAnchor: startupAnchor)
                inner.enumerateChanges(for: observer, from: anchor)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(startupAnchor)
    }
}

private extension String {
    /// For "a/b/c/d", returns "a/b/c/"
    func dropLastComponent() -> String {
        let parts = self.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/") + "/"
    }
}
