import FileProvider
import OSLog

private let log = Logger(subsystem: "com.toots.tsync", category: "Enumerator")

final class TsyncEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let domain: NSFileProviderDomain
    private let config: Config
    private let startupAnchor: NSFileProviderSyncAnchor

    init(containerIdentifier: NSFileProviderItemIdentifier,
         domain: NSFileProviderDomain,
         config: Config,
         startupAnchor: NSFileProviderSyncAnchor) {
        self.containerIdentifier = containerIdentifier
        self.domain = domain
        self.config = config
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

                let domainPrefix = config.domainPrefix(domain.displayName)
                let prefix = containerIdentifier == .rootContainer
                    ? domainPrefix
                    : containerIdentifier.rawValue

                let resp = try await IPC.listDir(prefix: prefix)
                var items: [TsyncItem] = []

                for dir in resp.dirs ?? [] {
                    items.append(TsyncItem(
                        identifier: NSFileProviderItemIdentifier(dir),
                        parent: containerIdentifier,
                        filename: dir.split(separator: "/").last.map(String.init) ?? dir,
                        isDirectory: true))
                }
                for entry in resp.files ?? [] {
                    items.append(TsyncItem(
                        identifier: NSFileProviderItemIdentifier(entry.key),
                        parent: containerIdentifier,
                        filename: entry.key.split(separator: "/").last.map(String.init) ?? entry.key,
                        isDirectory: false,
                        size: entry.size,
                        modificationDate: Date(timeIntervalSince1970: entry.mtime),
                        etag: entry.etag))
                }

                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(startupAnchor)
    }

    // MARK: - Private

    private func enumerateWorkingSet(observer: any NSFileProviderEnumerationObserver) async throws {
        let domainPrefix = config.domainPrefix(domain.displayName)
        let resp = try await IPC.listAll(prefix: domainPrefix)
        let items: [TsyncItem] = (resp.files ?? []).map { entry in
            let parent = TsyncItem.parentIdentifier(for: entry.key, domainPrefix: domainPrefix)
            return TsyncItem(
                identifier: NSFileProviderItemIdentifier(entry.key),
                parent: parent,
                filename: entry.key.split(separator: "/").last.map(String.init) ?? entry.key,
                isDirectory: false,
                size: entry.size,
                modificationDate: Date(timeIntervalSince1970: entry.mtime),
                etag: entry.etag)
        }
        log.info("enumerateWorkingSet: \(items.count, privacy: .public) items")
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
    }
}
