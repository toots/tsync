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
                let items = containerIdentifier == .workingSet
                    ? try await workingSetItems()
                    : try await containerItems()
                emitPage(items, from: pageOffset(page), to: observer)
            } catch {
                observer.finishEnumeratingWithError(IPC.fileProviderError(error))
            }
        }
    }

    private func containerItems() async throws -> [TsyncItem] {
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
        return items
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

    // ponytail: re-fetches the full listing on every page (O(n²) IPC for the working set's
    // recursive listAll). Fine until domains get huge; add offset/limit to the IPC then.
    private func workingSetItems() async throws -> [TsyncItem] {
        let domainPrefix = config.domainPrefix(domain.displayName)
        let resp = try await IPC.listAll(prefix: domainPrefix)
        // The working set holds files only: skip directory-marker keys, which would collide
        // with the real folders from the container enumeration.
        let files = (resp.files ?? []).filter { !$0.key.hasSuffix("/") }
        return files.map { entry in
            TsyncItem.make(
                key: entry.key, domainPrefix: domainPrefix,
                readOnly: isReadOnly,
                size: entry.size,
                modificationDate: Date(timeIntervalSince1970: entry.mtime),
                etag: entry.etag, symlinkTarget: entry.symlinkTarget)
        }
    }

    /// FileProvider SIGABRTs the extension (`__FILEPROVIDER_OBSERVER_TOO_MANY_ITEMS__`) if a
    /// single enumeration reports too many items without paginating, so we hand back one page
    /// at a time and let the OS re-call us with the next page's offset.
    private static let pageSize = 1000

    /// A page's rawValue is the byte offset into the listing; initial-page sentinels aren't
    /// integers and decode to 0 (start from the top). The listing is S3-key sorted, so the
    /// order is stable across the successive calls that walk the offsets.
    private func pageOffset(_ page: NSFileProviderPage) -> Int {
        guard let str = String(data: page.rawValue, encoding: .utf8), let offset = Int(str)
        else { return 0 }
        return offset
    }

    private func emitPage(_ items: [TsyncItem], from offset: Int,
                          to observer: any NSFileProviderEnumerationObserver) {
        let end = min(offset + Self.pageSize, items.count)
        if offset < end { observer.didEnumerate(Array(items[offset..<end])) }
        if end < items.count {
            observer.finishEnumerating(upTo: NSFileProviderPage("\(end)".data(using: .utf8)!))
        } else {
            observer.finishEnumerating(upTo: nil)
        }
    }
}
