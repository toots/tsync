import FileProvider
import OSLog

private let log = Logger(subsystem: "org.feverdreamtv.tsync", category: "WorkingSetEnumerator")

/// The one container change traffic goes through.
///
/// A replicated extension may signal only the working set, so this is where
/// every remote change is reported and the system propagates from here to the
/// replica and to Spotlight. Its items carry their real parent, not this
/// container: the working set is a view, not a folder.
///
/// `enumerateItems` is the expensive half and runs only when the anchor expires
/// — the system then drops what it knew and asks for the set from scratch. It is
/// bounded by the materialized directories rather than by the domain, which is
/// the whole reason for tracking them.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let client: DaemonClient
    private let materialized: MaterializedSet
    private let domainName: String
    private let readOnly: Bool

    init(client: DaemonClient, materialized: MaterializedSet,
         domainName: String, readOnly: Bool) {
        self.client = client
        self.materialized = materialized
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
            await materialized.refresh()
            do {
                let size = max(1, observer.suggestedBatchSize ?? 100)
                let batch = try await client.changesSince(since, limit: size)
                if batch.stale == true {
                    // The daemon no longer keeps entries reaching back this far.
                    observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                    return
                }
                let (updated, deleted) = ChangeBatch.resolve(
                    batch.ops ?? [], holds: materialized.holds, readOnly: readOnly)
                let seen = (batch.ops ?? []).map { "\($0.op):\($0.ref ?? "-")" }
                    .joined(separator: " ")
                let gone = deleted.map(\.rawValue).joined(separator: " ")
                log.debug("""
                    changes from \(since, privacy: .public): \
                    ops[\(seen, privacy: .public)] \
                    upd=\(updated.count, privacy: .public) \
                    del[\(gone, privacy: .public)]
                    """)
                if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
                if !updated.isEmpty { observer.didUpdate(updated) }
                // Past the ops that were filtered out as well as the ones
                // reported, or the feed never gets anywhere.
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

    /// Everything under a materialized directory, paged across them.
    ///
    /// The page names the directory reached and the last child served in it, so
    /// this resumes without holding either list.
    func enumerateItems(for observer: any NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        Task {
            await materialized.refresh()
            do {
                let size = max(1, observer.suggestedPageSize ?? 100)
                let cursor = WorkingSetPage.decode(Cursor.name(page))
                let containers = materialized.sorted()
                guard let index = containers.firstIndex(where: { $0 >= cursor.container })
                        ?? (containers.isEmpty ? nil : containers.count)
                else {
                    observer.finishEnumerating(upTo: nil)
                    return
                }
                guard index < containers.count else {
                    observer.finishEnumerating(upTo: nil)
                    return
                }
                let container = containers[index]
                let batch = try await client.listDir(container, after: cursor.after, limit: size)
                observer.didEnumerate(
                    batch.items.compactMap { TsyncItem.make($0, readOnly: readOnly) })
                if let next = batch.next {
                    observer.finishEnumerating(
                        upTo: WorkingSetPage.encode(container: container, after: next))
                } else if index + 1 < containers.count {
                    observer.finishEnumerating(
                        upTo: WorkingSetPage.encode(container: containers[index + 1], after: nil))
                } else {
                    observer.finishEnumerating(upTo: nil)
                }
            } catch {
                log.error("enumerateItems(workingSet): \(error, privacy: .public)")
                observer.finishEnumeratingWithError(FileProviderError.from(error))
            }
        }
    }
}
