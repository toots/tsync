import FileProvider
import OSLog

private let log = Logger(subsystem: "org.feverdreamtv.tsync", category: "WorkingSetEnumerator")

/// The one container change traffic goes through.
///
/// A replicated extension may signal only the working set, so this is where
/// every remote change is reported and the system propagates from here to the
/// replica and to Spotlight. Its items carry their real parent, not this
/// container: the working set is a view, not a folder.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let client: DaemonClient
    private let domainName: String
    private let readOnly: Bool

    init(client: DaemonClient, domainName: String, readOnly: Bool) {
        self.client = client
        self.domainName = domainName
        self.readOnly = readOnly
    }

    func invalidate() {}

    // MARK: - Changes

    func enumerateChanges(for observer: any NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        Task {
            let (token, since) = Anchor.decode(anchor)
            guard token == Config.resyncToken(domain: domainName) else {
                // The mirror was rebuilt after this anchor was issued, so no
                // delta bridges it.
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }
            do {
                let size = max(1, observer.suggestedBatchSize ?? 100)
                let batch = try await client.changesSince(since, limit: size)
                if batch.stale == true {
                    // Entries reaching back this far are past the daemon's
                    // retention, so the delta has a hole in it.
                    observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                    return
                }
                let (updated, deleted) = ChangeBatch.resolve(batch.ops ?? [], readOnly: readOnly)
                let seen = (batch.ops ?? []).map { "\($0.op):\($0.ref ?? "-")" }
                    .joined(separator: " ")
                log.debug("""
                    changes from \(since, privacy: .public): \
                    ops[\(seen, privacy: .public)] \
                    upd=\(updated.count, privacy: .public) \
                    del=\(deleted.count, privacy: .public)
                    """)
                if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
                if !updated.isEmpty { observer.didUpdate(updated) }
                observer.finishEnumeratingChanges(
                    upTo: Anchor.encode(token: token, cursor: batch.cursor ?? since),
                    moreComing: batch.more ?? false)
            } catch {
                // Never finish at the anchor we started from: that claims the
                // client is up to date, and the system stops asking for as long
                // as the domain lives.
                log.error("enumerateChanges: \(error, privacy: .public)")
                observer.finishEnumeratingWithError(FileProviderError.from(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            do {
                completionHandler(Anchor.encode(
                    token: Config.resyncToken(domain: domainName),
                    cursor: try await client.currentCursor()))
            } catch {
                // No anchor rather than an invented one: a made-up cursor comes
                // back unparseable and costs a full rescan.
                completionHandler(nil)
            }
        }
    }

    // MARK: - Items

    /// The whole domain, a page at a time: a fresh anchor is paired with a full
    /// enumeration, which is what the system asks for here.
    ///
    /// The page is the daemon's cursor for the last item served, bounded like a
    /// reference, so nothing is held between calls and a page means the same to
    /// a process that did not issue it.
    func enumerateItems(for observer: any NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        Task {
            do {
                let size = max(1, observer.suggestedPageSize ?? 100)
                let batch = try await client.listAll(after: Cursor.name(page), limit: size)
                observer.didEnumerate(
                    batch.items.compactMap { TsyncItem.make($0, readOnly: readOnly) })
                observer.finishEnumerating(upTo: batch.next.flatMap(Cursor.page))
            } catch {
                log.error("enumerateItems(workingSet): \(error, privacy: .public)")
                observer.finishEnumeratingWithError(FileProviderError.from(error))
            }
        }
    }
}
