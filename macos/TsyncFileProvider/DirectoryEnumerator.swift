import FileProvider
import OSLog

private let log = Logger(subsystem: "org.feverdreamtv.tsync", category: "DirectoryEnumerator")

/// One folder, listed a page at a time.
///
/// Items only. It deliberately implements neither `enumerateChanges` nor
/// `currentSyncAnchor`: a replicated extension may signal only the working set,
/// and the system propagates from there to the replica, so a directory's change
/// enumeration is never triggered and anything reported through one would be
/// answering for a container the ops do not belong to.
///
/// Nothing is held between pages. The page cursor is the last name served, so a
/// resumed enumeration re-asks the daemon and picks up after that name — which
/// is what makes it survive this process being stopped mid-listing, and what
/// stops an item added or removed in between shifting everything after it.
final class DirectoryEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let container: NSFileProviderItemIdentifier
    private let client: DaemonClient
    private let readOnly: Bool

    init(container: NSFileProviderItemIdentifier, client: DaemonClient, readOnly: Bool) {
        self.container = container
        self.client = client
        self.readOnly = readOnly
    }

    func invalidate() {}

    func enumerateItems(for observer: any NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        let ref = ItemID.wire(container)
        Task {
            do {
                // The system's own figure for this enumeration: it knows whether
                // a person is watching a window or a process is walking the tree.
                let size = max(1, observer.suggestedPageSize ?? 100)
                let batch = try await client.listDir(ref, after: Cursor.name(page), limit: size)
                observer.didEnumerate(
                    batch.items.compactMap { TsyncItem.make($0, readOnly: readOnly) })
                observer.finishEnumerating(upTo: batch.next.flatMap(Cursor.page))
            } catch {
                log.error("enumerateItems \(ref, privacy: .public): \(error, privacy: .public)")
                observer.finishEnumeratingWithError(FileProviderError.from(error))
            }
        }
    }
}
