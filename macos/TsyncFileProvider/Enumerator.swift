import FileProvider
import OSLog

private let log = Logger(subsystem: "org.feverdreamtv.tsync", category: "Enumerator")

final class TsyncEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let container: NSFileProviderItemIdentifier
    private let client: DaemonClient
    private let domainName: String
    private let readOnly: Bool

    /// The listing this enumeration is walking. Fetched once and paged from
    /// memory: the system asks for page after page from the same enumerator, and
    /// re-listing per page would both cost a round trip each time and let the
    /// contents shift underneath, which shows up as items skipped or repeated.
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
        // The working set lists the domain's top level, not the whole tree.
        // Enumerating everything is the other documented option, and it was tried
        // here: on a real media domain it left the extension re-listing the tree
        // continuously and the daemon resolving a manifest per file, at hundreds
        // of megabytes of resident memory, without ever settling. Nothing was
        // gained for it — remote changes reach the system through
        // enumerateChanges below, which reports items at any depth straight from
        // the journal.
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

    /// A page's rawValue is an offset into the listing above; the initial-page
    /// sentinels are not integers and read as zero.
    private func offset(of page: NSFileProviderPage) -> Int {
        guard let s = String(data: page.rawValue, encoding: .utf8),
              let n = Int(s) else { return 0 }
        return n
    }

    private func emit(_ items: [DaemonItem], from offset: Int,
                      to observer: any NSFileProviderEnumerationObserver) {
        // Reporting too much at once aborts the extension with
        // __FILEPROVIDER_OBSERVER_TOO_MANY_ITEMS__, which is the system enforcing
        // a hundred times the size it asked for. Ask what it wants rather than
        // guessing a number.
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
                // The daemon rebuilt its mirror since this anchor was handed out,
                // so no delta can bridge it.
                observer.finishEnumeratingWithError(
                    NSFileProviderError(.syncAnchorExpired))
                return
            }
            do {
                let response = try await client.changesSince(cursor)
                if response.stale == true {
                    // The journal no longer reaches back this far, or a change
                    // names something this client cannot describe yet.
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
                // Never report success here. Finishing at the anchor we started
                // from claims the client is up to date, so the system stops
                // asking — and a failure then looks exactly like "nothing
                // changed", for as long as the domain lives.
                log.error("enumerateChanges failed: \(error, privacy: .public)")
                observer.finishEnumeratingWithError(FileProviderError.from(error))
            }
        }
    }

    /// Turn journal ops into the two sets the observer takes.
    ///
    /// The ops are ordered but the observer's sets are not, so only a reference's
    /// *last* op may be reported: a key created and then deleted in one batch
    /// would otherwise be resurrected by the creation.
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

            // A rename's source is gone unless something later put it back. A
            // directory keeps its reference across a move, so this only fires for
            // a file, or for a directory that genuinely became something else.
            if let src = op.srcRef, src != ref, (lastIndex[src] ?? -1) < i,
               let srcID = ItemID.parse(src) {
                deleted.append(srcID.identifier)
            }

            switch op.op {
            case "delete", "rmdir":
                deleted.append(id.identifier)
            default:
                // put, mkdir, rename. Ask what the item looks like now; if it has
                // gone in the meantime, report that instead of a stale creation.
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
                // No anchor rather than an invented one. A made-up anchor would be
                // handed back later as a cursor the daemon cannot parse, buying a
                // full rescan to learn what asking again would have said.
                completionHandler(nil)
            }
        }
    }

    // MARK: - Anchors

    /// An anchor records which generation of the mirror it was issued against, so
    /// a resync invalidates every outstanding one without having to reach them.
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
