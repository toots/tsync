import FileProvider
import Foundation

/// A folder's children, listed once when the system materialises it (§6.5).
/// Folder enumerators are never asked for changes; the working set reports them.
final class DirectoryEnumerator: NSObject, NSFileProviderEnumerator {
    let owner: Owner
    let ref: String
    let cancellation = Cancellation()

    init(owner: Owner, ref: String) {
        self.owner = owner
        self.ref = ref
    }

    func invalidate() { cancellation.cancel() }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
    ) {
        let after: String?
        do { after = try Cursors.resume(from: page) } catch {
            observer.finishEnumeratingWithError(error)
            return
        }
        let limit = Cursors.limit(observer.suggestedPageSize ?? 0)
        detached { [owner, ref, cancellation] in
            do {
                var fields: [String: Any] = ["ref": ref, "limit": limit]
                if let after = after { fields["after"] = after }
                let reply = try owner.call("list_dir", fields, cancellation: cancellation)
                let items = (reply["items"] as? [[String: Any]] ?? []).compactMap(Row.init)
                observer.didEnumerate(items.map(Item.init))
                if let next = reply["next"] as? String {
                    guard let page = Cursors.page(next) else {
                        observer.finishEnumeratingWithError(
                            Errors.cocoa(.fileReadUnknown, OwnerFailure.transport("page over 500 bytes")))
                        return
                    }
                    observer.finishEnumerating(upTo: page)
                } else {
                    observer.finishEnumerating(upTo: nil)
                }
            } catch {
                observer.finishEnumeratingWithError(
                    Errors.map(error, .read, missing: ItemRef.identifier(ref)))
            }
        }
    }
}

/// The whole domain (§6.5, §5): pages over the owner's kept walk, changes from
/// its applied log, anchors that are the owner's own strings.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    let owner: Owner
    let cancellation = Cancellation()

    init(owner: Owner) {
        self.owner = owner
    }

    func invalidate() { cancellation.cancel() }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
    ) {
        let after: String?
        do { after = try Cursors.resume(from: page) } catch {
            observer.finishEnumeratingWithError(error)
            return
        }
        let limit = Cursors.limit(observer.suggestedPageSize ?? 0)
        log.info("working set: list from \(after ?? "the start", privacy: .public)")
        detached { [owner, cancellation] in
            do {
                var fields: [String: Any] = ["limit": limit]
                if let after = after { fields["after"] = after }
                // A first page walks the whole domain: bulk, watched by the
                // liveness probe instead of bounded by the request deadline.
                let reply =
                    after == nil
                    ? try owner.bulk("list_all", fields, cancellation: cancellation)
                    : try owner.call("list_all", fields, cancellation: cancellation)
                // A cursor on another walk: the system restarts the listing.
                if reply["stale"] as? Bool == true {
                    observer.finishEnumeratingWithError(
                        Errors.provider(.pageExpired, OwnerFailure.transport("the walk was remade")))
                    return
                }
                let items = (reply["items"] as? [[String: Any]] ?? []).compactMap(Row.init)
                observer.didEnumerate(items.map(Item.init))
                if let next = reply["next"] as? String {
                    guard let page = Cursors.page(next) else {
                        observer.finishEnumeratingWithError(
                            Errors.cocoa(.fileReadUnknown, OwnerFailure.transport("page over 500 bytes")))
                        return
                    }
                    observer.finishEnumerating(upTo: page)
                } else {
                    observer.finishEnumerating(upTo: nil)
                }
            } catch {
                observer.finishEnumeratingWithError(Errors.map(error, .read))
            }
        }
    }

    /// On any error, finish with the error, never at the starting anchor:
    /// that would claim "up to date" and the system would stop asking.
    func enumerateChanges(
        for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
    ) {
        guard let from = Cursors.cursor(of: anchor) else {
            observer.finishEnumeratingWithError(
                Errors.provider(.syncAnchorExpired, OwnerFailure.transport("not an anchor")))
            return
        }
        let limit = Cursors.limit(observer.suggestedBatchSize ?? 0)
        log.info("working set: changes from \(from, privacy: .public)")
        detached { [owner, cancellation] in
            do {
                let reply = try owner.call(
                    "changes_since", ["arg": from, "limit": limit], cancellation: cancellation)
                if reply["stale"] as? Bool == true {
                    observer.finishEnumeratingWithError(
                        Errors.provider(.syncAnchorExpired, OwnerFailure.transport("stale anchor")))
                    return
                }
                guard let cursor = reply["cursor"] as? String, let next = Cursors.anchor(cursor)
                else {
                    observer.finishEnumeratingWithError(
                        Errors.cocoa(.fileReadUnknown, OwnerFailure.transport("no usable cursor")))
                    return
                }
                let batch = ChangeBatch(ops: reply["ops"] as? [[String: Any]] ?? [])
                if !batch.deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: batch.deleted.map(ItemRef.identifier))
                }
                if !batch.updated.isEmpty {
                    observer.didUpdate(batch.updated.map(Item.init))
                }
                observer.finishEnumeratingChanges(
                    upTo: next, moreComing: reply["more"] as? Bool ?? false)
            } catch {
                observer.finishEnumeratingWithError(Errors.map(error, .read))
            }
        }
    }

    /// On failure, no anchor: an invented one costs a rescan.
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        detached { [owner] in
            let cursor = (try? owner.call("cursor"))?["cursor"] as? String
            log.info("working set: anchor \(cursor ?? "none", privacy: .public)")
            completionHandler(cursor.flatMap(Cursors.anchor))
        }
    }
}

/// The trash is not implemented (§6.4).
final class TrashEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
    ) {
        observer.finishEnumeratingWithError(
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.featureUnsupported.rawValue))
    }
}
