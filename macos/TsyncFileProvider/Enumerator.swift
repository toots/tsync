import FileProvider
import OSLog

private let log = Logger(subsystem: "org.feverdreamtv.tsync", category: "Enumerator")

final class TsyncEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let container: NSFileProviderItemIdentifier
    private let client: DaemonClient
    private let domainName: String
    private let readOnly: Bool

    /// Fetched once and paged from memory: re-listing per page would cost a
    /// round trip each time and let the contents shift underneath, showing up as
    /// items skipped or repeated.
    private var page: [DaemonItem]?

    init(container: NSFileProviderItemIdentifier, client: DaemonClient,
         domainName: String, readOnly: Bool) {
        self.container = container
        self.client = client
        self.domainName = domainName
        self.readOnly = readOnly
    }

    func invalidate() { page = nil }

    // MARK: - Items

    func enumerateItems(for observer: any NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        Task {
            do {
                let items = try await listing()
                emit(items, from: offset(of: page), to: observer)
            } catch {
                observer.finishEnumeratingWithError(FileProviderError.from(error))
            }
        }
    }

    private func listing() async throws -> [DaemonItem] {
        if let page { return page }
        // Top level only. Enumerating the whole tree is the other documented
        // option; on a real media domain it left the extension re-listing
        // continuously at hundreds of megabytes resident without settling, and
        // gained nothing — enumerateChanges below reports items at any depth.
        //
        // ponytail: an item outside the working set whose parent is never browsed
        // learns about changes only through that change feed. Track the
        // materialised set via materializedItemsDidChangeWithCompletionHandler if
        // that ever proves too little.
        let target = container == .workingSet ? ItemID.rootForm : ItemID.wire(container)
        let items = try await client.listDir(target)
        page = items
        return items
    }

    /// A page's rawValue is an offset into the listing; the initial-page
    /// sentinels are not integers and read as zero.
    private func offset(of page: NSFileProviderPage) -> Int {
        guard let s = String(data: page.rawValue, encoding: .utf8),
              let n = Int(s) else { return 0 }
        return n
    }

    private func emit(_ items: [DaemonItem], from offset: Int,
                      to observer: any NSFileProviderEnumerationObserver) {
        // Over a hundred times the requested page size, the system aborts the
        // extension with __FILEPROVIDER_OBSERVER_TOO_MANY_ITEMS__.
        let size = observer.suggestedPageSize ?? 100
        let end = min(offset + max(size, 1), items.count)
        if offset < end {
            observer.didEnumerate(items[offset..<end].compactMap {
                TsyncItem.make($0, readOnly: readOnly)
            })
        }
        if end < items.count {
            observer.finishEnumerating(upTo: NSFileProviderPage("\(end)".data(using: .utf8)!))
        } else {
            observer.finishEnumerating(upTo: nil)
        }
    }

    // MARK: - Changes

    func enumerateChanges(for observer: any NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        Task {
            let (token, cursor) = decode(anchor)
            guard token == Config.resyncToken(domain: domainName) else {
                // The mirror was rebuilt since this anchor was issued, so no
                // delta can bridge it.
                observer.finishEnumeratingWithError(
                    NSFileProviderError(.syncAnchorExpired))
                return
            }
            do {
                let response = try await client.changesSince(cursor)
                if response.stale == true {
                    // The journal no longer reaches back this far, or names
                    // something this client cannot describe.
                    observer.finishEnumeratingWithError(
                        NSFileProviderError(.syncAnchorExpired))
                    return
                }
                let (updated, deleted) = try await resolve(response.ops ?? [])
                if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
                if !updated.isEmpty { observer.didUpdate(updated) }
                observer.finishEnumeratingChanges(
                    upTo: encode(cursor: response.cursor ?? cursor), moreComing: false)
            } catch {
                // Never report success: finishing at the anchor we started from
                // claims the client is up to date and the system stops asking,
                // for as long as the domain lives.
                log.error("enumerateChanges failed: \(error, privacy: .public)")
                observer.finishEnumeratingWithError(FileProviderError.from(error))
            }
        }
    }

    /// Turn journal ops into the two sets the observer takes.
    ///
    /// The ops are ordered but the observer's sets are not, so only a reference's
    /// last op may be reported: a key created then deleted in one batch would
    /// otherwise be resurrected by the creation.
    private func resolve(_ ops: [DaemonOp]) async throws
        -> ([NSFileProviderItem], [NSFileProviderItemIdentifier]) {
        var lastIndex: [String: Int] = [:]
        for (i, op) in ops.enumerated() {
            if let ref = op.ref { lastIndex[ref] = i }
        }

        var updated: [NSFileProviderItem] = []
        var deleted: [NSFileProviderItemIdentifier] = []

        for (i, op) in ops.enumerated() {
            guard let ref = op.ref, lastIndex[ref] == i,
                  let id = ItemID.parse(ref) else { continue }

            // A directory keeps its reference across a move, so this fires only
            // for a file, or a directory that became something else.
            if let src = op.srcRef, src != ref, (lastIndex[src] ?? -1) < i,
               let srcID = ItemID.parse(src) {
                deleted.append(srcID.identifier)
            }

            switch op.op {
            case "delete", "rmdir":
                deleted.append(id.identifier)
            default:
                // put, mkdir, rename. An item gone in the meantime is reported
                // as such rather than as a stale creation.
                do {
                    let item = try await client.stat(ref)
                    if let built = TsyncItem.make(item, readOnly: readOnly) {
                        updated.append(built)
                    }
                } catch let error as DaemonError where error.code == "not_found" {
                    deleted.append(id.identifier)
                }
            }
        }
        return (updated, deleted)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            do {
                completionHandler(encode(cursor: try await client.currentCursor()))
            } catch {
                // No anchor rather than an invented one: a made-up cursor comes
                // back unparseable and costs a full rescan.
                completionHandler(nil)
            }
        }
    }

    // MARK: - Anchors

    /// An anchor records the mirror generation it was issued against, so a
    /// resync invalidates every outstanding one without reaching them.
    private func encode(cursor: String) -> NSFileProviderSyncAnchor {
        let token = Config.resyncToken(domain: domainName)
        return NSFileProviderSyncAnchor("\(token)|\(cursor)".data(using: .utf8)!)
    }

    private func decode(_ anchor: NSFileProviderSyncAnchor) -> (String, String) {
        let raw = String(data: anchor.rawValue, encoding: .utf8) ?? ""
        guard let sep = raw.firstIndex(of: "|") else { return ("", raw) }
        return (String(raw[raw.startIndex..<sep]),
                String(raw[raw.index(after: sep)...]))
    }
}
