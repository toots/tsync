import FileProvider
import OSLog

private let log = Logger(subsystem: "org.feverdreamtv.tsync", category: "MaterializedSet")

/// Which directories the system holds on disk.
///
/// The roles are reversed here: everywhere else the system asks us, but the
/// materialized set is ours to ask for, and the system tells us when it moved by
/// calling `materializedItemsDidChange`.
///
/// It is what decides which remote changes are worth reporting. A materialized
/// directory's children are on disk and no enumeration will be asked for them
/// again, so the extension is the only thing that can invalidate them; a change
/// under a directory the system does not hold is one it would drop anyway.
///
/// Until the first refresh lands this answers `true` for everything. That is the
/// documented fallback — the working set becomes the whole dataset — and it is
/// the safe direction: over-reporting costs traffic, while under-reporting loses
/// a change silently and for as long as the domain lives.
///
/// ponytail: rebuilt in full rather than kept on disk with its own anchor. The
/// set is only what has actually been browsed, and the enumerator supports
/// changes-from-an-anchor if a rebuild per activation ever shows up.
final class MaterializedSet: @unchecked Sendable {
    private let domain: NSFileProviderDomain
    private let lock = NSLock()
    private var directories: Set<String> = []
    private var loaded = false
    private var refreshing = false

    init(domain: NSFileProviderDomain) {
        self.domain = domain
    }

    /// Whether a change under `ref` is one the system is holding a place for.
    func holds(_ ref: String?) -> Bool {
        guard let ref else { return false }
        lock.lock()
        defer { lock.unlock() }
        return !loaded || directories.contains(ref)
    }

    /// The containers to walk, in a fixed order, so a page naming one resumes
    /// at the same place a later call would.
    func sorted() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return directories.sorted()
    }

    /// Refresh unless one is already running. Called from
    /// `materializedItemsDidChange`, which fires on every change to the set, and
    /// once before the first enumeration of the working set.
    func refresh() async {
        lock.lock()
        if refreshing {
            lock.unlock()
            // The caller reads the set as soon as this returns, and an
            // enumeration served from one no refresh has filled yet answers for
            // an empty domain.
            while true {
                try? await Task.sleep(nanoseconds: 25_000_000)
                lock.lock()
                let busy = refreshing
                lock.unlock()
                if !busy { return }
            }
        }
        refreshing = true
        lock.unlock()

        defer {
            lock.lock()
            refreshing = false
            lock.unlock()
        }

        guard let manager = NSFileProviderManager(for: domain) else { return }
        do {
            let found = try await enumerateAll(manager.enumeratorForMaterializedItems())
            lock.lock()
            directories = found
            loaded = true
            lock.unlock()
            log.debug("materialized directories: \(found.count)")
        } catch {
            // Left as it was, which for a first run means still answering true
            // for everything rather than nothing.
            log.error("materialized set: \(error, privacy: .public)")
        }
    }

    /// Directories only: a change is tested against its parent, and a file is
    /// never one. Paged, because the set counts everything on disk and not just
    /// the containers.
    private func enumerateAll(_ enumerator: NSFileProviderEnumerator) async throws -> Set<String> {
        var found: Set<String> = []
        // The materialized enumerator takes an empty page rather than one of the
        // sort sentinels, which it ignores.
        var page = NSFileProviderPage(Data())
        while true {
            let batch = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(items: [NSFileProviderItem],
                                                    next: NSFileProviderPage?), Error>) in
                enumerator.enumerateItems(for: PageCollector(continuation), startingAt: page)
            }
            for item in batch.items where item.contentType == .folder {
                found.insert(ItemID.wire(item.itemIdentifier))
            }
            guard let next = batch.next else { break }
            page = next
        }
        // The root is materialized by definition: the domain's own folder exists
        // as soon as it is registered, and nothing enumerates it as an item.
        found.insert(ItemID.rootForm)
        return found
    }
}

/// One page of an enumeration, handed back as a value.
///
/// The system's enumerators are callback-shaped in both directions; this is the
/// adapter for the direction where we are the observer. It resumes exactly once
/// however the enumeration ends.
private final class PageCollector: NSObject, NSFileProviderEnumerationObserver {
    private var continuation: CheckedContinuation<(items: [NSFileProviderItem],
                                                   next: NSFileProviderPage?), Error>?
    private var items: [NSFileProviderItem] = []
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<(items: [NSFileProviderItem],
                                              next: NSFileProviderPage?), Error>) {
        self.continuation = continuation
    }

    private func finish(_ result: Result<(items: [NSFileProviderItem],
                                          next: NSFileProviderPage?), Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) {
        lock.lock()
        items.append(contentsOf: updatedItems)
        lock.unlock()
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        lock.lock()
        let collected = items
        lock.unlock()
        finish(.success((collected, nextPage)))
    }

    func finishEnumeratingWithError(_ error: Error) {
        finish(.failure(error))
    }
}
