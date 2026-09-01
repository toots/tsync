import FileProvider

/// A batch of daemon ops as the two sets an observer takes.
///
/// Free of the domain and of the daemon so the rules below can be checked on
/// their own: what they get wrong is not visible in a listing, it is an item
/// that quietly stops existing or comes back from the dead.
enum ChangeBatch {
    static func resolve(_ ops: [DaemonOp], readOnly: Bool)
        -> (updated: [NSFileProviderItem], deleted: [NSFileProviderItemIdentifier]) {
        // The ops are ordered and the observer's two sets are not, so only an
        // item's last op may be reported: a file created and then deleted in one
        // batch would otherwise be resurrected by the creation.
        var lastIndex: [String: Int] = [:]
        for (i, op) in ops.enumerated() {
            if let ref = op.ref { lastIndex[ref] = i }
        }

        var updated: [NSFileProviderItem] = []
        var deleted: [NSFileProviderItemIdentifier] = []

        for (i, op) in ops.enumerated() {
            guard let ref = op.ref, lastIndex[ref] == i, let id = ItemID.parse(ref)
            else { continue }

            // A directory keeps its reference across a move, so this fires only
            // for a file, or a directory that became something else.
            if let src = op.srcRef, src != ref, (lastIndex[src] ?? -1) < i,
               let srcID = ItemID.parse(src) {
                deleted.append(srcID.identifier)
            }

            if op.isDeletion {
                deleted.append(id.identifier)
            } else if let item = op.item, let built = TsyncItem.make(item, readOnly: readOnly) {
                updated.append(built)
            }
        }
        return (updated, deleted)
    }
}
