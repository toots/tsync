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
                    items.append(TsyncItem.make(
                        key: dir.key, domainPrefix: domainPrefix, readOnly: isReadOnly,
                        modificationDate: dir.mtime.map { Date(timeIntervalSince1970: $0) }))
                }
                for entry in resp.files ?? [] {
                    items.append(TsyncItem.make(
                        key: entry.key, domainPrefix: domainPrefix,
                        readOnly: isReadOnly,
                        size: entry.size,
                        modificationDate: Date(timeIntervalSince1970: entry.mtime),
                        etag: entry.etag, symlinkTarget: entry.symlinkTarget))
                }

                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(IPC.fileProviderError(error))
            }
        }
    }

    func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        Task {
            let anchorStr = String(data: anchor.rawValue, encoding: .utf8) ?? ""
            do {
                // "0" is the sentinel empty cursor; the daemon wants "" for "from the start".
                let resp = try await IPC.changesSince(anchor: anchorStr == "0" ? "" : anchorStr,
                                                      domain: domain.displayName)
                // The journal was pruned past our anchor (or was cleaned up entirely): we
                // can't produce a complete delta, so tell the OS to drop its cache and
                // re-run enumerateItems for a full re-list.
                if resp.stale == true {
                    observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                    return
                }
                var updated: [TsyncItem] = []
                var deleted: [NSFileProviderItemIdentifier] = []
                for op in resp.ops ?? [] {
                    switch op.op {
                    case "delete", "rmdir":
                        deleted.append(NSFileProviderItemIdentifier(op.key))
                    case "rename":
                        if let src = op.src { deleted.append(NSFileProviderItemIdentifier(src)) }
                        if let item = try? await resolveChangeItem(op.key) { updated.append(item) }
                    default: // put, mkdir
                        if let item = try? await resolveChangeItem(op.key) { updated.append(item) }
                    }
                }
                if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
                if !updated.isEmpty { observer.didUpdate(updated) }
                observer.finishEnumeratingChanges(upTo: syncAnchor(resp.cursor ?? anchorStr), moreComing: false)
            } catch {
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            do {
                let resp = try await IPC.currentCursor(domain: domain.displayName)
                completionHandler(syncAnchor(resp.cursor ?? ""))
            } catch {
                completionHandler(startupAnchor)
            }
        }
    }

    // MARK: - Private

    private var isReadOnly: Bool { config.isReadOnly(domain.displayName) }

    /// Sync anchors must carry non-empty data; use "0" as the empty-cursor sentinel.
    private func syncAnchor(_ cursor: String) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor((cursor.isEmpty ? "0" : cursor).data(using: .utf8)!)
    }

    /// Build the item for a key touched by a journal op (directories end in "/").
    private func resolveChangeItem(_ key: String) async throws -> TsyncItem {
        let domainPrefix = config.domainPrefix(domain.displayName)
        if key.hasSuffix("/") {
            return TsyncItem.make(key: key, domainPrefix: domainPrefix, readOnly: isReadOnly)
        }
        let resp = try await IPC.stat(key: key)
        return TsyncItem.make(key: key, domainPrefix: domainPrefix,
                              readOnly: isReadOnly,
                              size: resp.size,
                              modificationDate: resp.mtime.map { Date(timeIntervalSince1970: $0) },
                              etag: resp.etag, isUploaded: resp.isUploaded ?? true,
                              symlinkTarget: resp.symlinkTarget)
    }

    private func enumerateWorkingSet(observer: any NSFileProviderEnumerationObserver) async throws {
        let domainPrefix = config.domainPrefix(domain.displayName)
        let resp = try await IPC.listAll(prefix: domainPrefix)
        // The working set holds files only: skip directory-marker keys, which would collide
        // with the real folders from the container enumeration.
        let files = (resp.files ?? []).filter { !$0.key.hasSuffix("/") }
        let items: [TsyncItem] = files.map { entry in
            TsyncItem.make(
                key: entry.key, domainPrefix: domainPrefix,
                readOnly: isReadOnly,
                size: entry.size,
                modificationDate: Date(timeIntervalSince1970: entry.mtime),
                etag: entry.etag, symlinkTarget: entry.symlinkTarget)
        }
        log.info("enumerateWorkingSet: \(items.count, privacy: .public) items")
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
    }
}
