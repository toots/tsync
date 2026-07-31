import FileProvider
import OSLog

private let log = Logger(subsystem: "org.feverdreamtv.tsync", category: "Enumerator")

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
                let items = try await containerItems()
                emitPage(items, from: pageOffset(page), to: observer)
            } catch {
                observer.finishEnumeratingWithError(IPC.fileProviderError(error))
            }
        }
    }

    private func containerItems() async throws -> [TsyncItem] {
        let domainPrefix = config.domainPrefix(domain.displayName)
        // Enumerate one level at a time: the root and the working set both list the
        // domain's top level; the OS pulls deeper containers on demand. (Enumerating
        // the whole tree for the working set hangs on large domains.)
        let prefix = containerIdentifier == .rootContainer
            || containerIdentifier == .workingSet
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
            let (anchorToken, anchorCursor) = decodeAnchor(anchor)
            // The daemon rebuilt its mirror wholesale since this anchor was issued, so no
            // journal delta can bridge it — same recovery as a pruned journal below.
            guard anchorToken == resyncToken else {
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }
            do {
                let resp = try await IPC.changesSince(anchor: anchorCursor,
                                                      domain: domain.displayName)
                // The journal was pruned past our anchor (or was cleaned up entirely): we
                // can't produce a complete delta, so tell the OS to drop its cache and
                // re-run enumerateItems for a full re-list.
                if resp.stale == true {
                    observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                    return
                }
                // Ops are in journal order and a key can be created and later deleted in the
                // same batch, but the observer takes deletions and updates as two unordered
                // sets — so only a key's *last* op may be reported, or the earlier creation
                // resurrects what the later deletion removed.
                let ops = resp.ops ?? []
                var lastIndex: [String: Int] = [:]
                for (i, op) in ops.enumerated() { lastIndex[op.key] = i }

                var updated: [TsyncItem] = []
                var deleted: [NSFileProviderItemIdentifier] = []
                for (i, op) in ops.enumerated() where lastIndex[op.key] == i {
                    switch op.op {
                    case "delete", "rmdir":
                        deleted.append(NSFileProviderItemIdentifier(op.key))
                    case "rename":
                        // The source is gone unless something later put it back.
                        if let src = op.src, (lastIndex[src] ?? -1) < i {
                            deleted.append(NSFileProviderItemIdentifier(src))
                        }
                        if let item = try? await resolveChangeItem(op.key) { updated.append(item) }
                    default: // put, mkdir
                        if let item = try? await resolveChangeItem(op.key) { updated.append(item) }
                    }
                }
                if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
                if !updated.isEmpty { observer.didUpdate(updated) }
                observer.finishEnumeratingChanges(upTo: syncAnchor(resp.cursor ?? anchorCursor), moreComing: false)
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

    /// Stamped by the daemon each time it rebuilds the local mirror from the backend
    /// listing (`tsync sync --full`, `tsync fileprovider reimport`). Read per call rather
    /// than cached: the stamp lands while this extension is stopped as often as not.
    private var resyncToken: String {
        let url = Config.groupContainerURL
            .appendingPathComponent("tsync/resync-\(domain.displayName)")
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Anchors are "<resync token>|<cursor>", so an anchor records the mirror generation
    /// it was issued against and a later resync invalidates it on sight.
    private func syncAnchor(_ cursor: String) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor("\(resyncToken)|\(cursor)".data(using: .utf8)!)
    }

    /// Anchors predating that encoding — and the startup anchor — carry no separator.
    /// They decode to an empty token, which matches while no resync has ever been
    /// stamped and expires them once one has.
    private func decodeAnchor(_ anchor: NSFileProviderSyncAnchor) -> (String, String) {
        let raw = String(data: anchor.rawValue, encoding: .utf8) ?? ""
        guard let sep = raw.firstIndex(of: "|") else {
            // "0" was the old empty-cursor sentinel; the daemon wants "" for "from the start".
            return ("", raw == "0" ? "" : raw)
        }
        return (String(raw[raw.startIndex..<sep]), String(raw[raw.index(after: sep)...]))
    }

    /// Build the item for a key touched by a journal op (directories end in "/").
    /// Directories go through stat like files do: it is what proves the key still
    /// exists, so a stale creation op can't re-add something already deleted.
    private func resolveChangeItem(_ key: String) async throws -> TsyncItem {
        let domainPrefix = config.domainPrefix(domain.displayName)
        let resp = try await IPC.stat(key: key)
        return TsyncItem.make(key: key, domainPrefix: domainPrefix,
                              readOnly: isReadOnly,
                              size: resp.size,
                              modificationDate: resp.mtime.map { Date(timeIntervalSince1970: $0) },
                              etag: resp.etag, isUploaded: resp.isUploaded ?? true,
                              symlinkTarget: resp.symlinkTarget)
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
