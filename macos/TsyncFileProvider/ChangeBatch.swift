import FileProvider

/// A batch of daemon ops as the two sets an observer takes.
///
/// Free of the domain and of the daemon so the rules below can be checked on
/// their own: what they get wrong is not visible in a listing, it is an item
/// that quietly stops existing or comes back from the dead.
enum ChangeBatch {
    static func resolve(_ ops: [DaemonOp], readOnly: Bool)
        -> (updated: [NSFileProviderItem], deleted: [NSFileProviderItemIdentifier]) {
        // The ops are ordered and the observer's two sets are not, so an
        // identifier is decided by the last op that mentions it, as the item or
        // as what a rename left behind. A file created and then deleted in one
        // batch would otherwise be resurrected by the creation, and one renamed
        // and then removed would keep its old name on disk.
        var lastMention: [String: Int] = [:]
        for (i, op) in ops.enumerated() {
            if let ref = op.ref { lastMention[ref] = i }
            if let src = op.srcRef { lastMention[src] = i }
        }

        var updated: [NSFileProviderItem] = []
        var deleted: [NSFileProviderItemIdentifier] = []

        for (i, op) in ops.enumerated() {
            // A directory keeps its reference across a move, so this fires only
            // for a file, or a directory that became something else.
            if let src = op.srcRef, src != op.ref, lastMention[src] == i,
               let srcID = ItemID.parse(src) {
                deleted.append(srcID.identifier)
            }

            guard let ref = op.ref, lastMention[ref] == i, let id = ItemID.parse(ref)
            else { continue }
            if op.isDeletion {
                deleted.append(id.identifier)
            } else if let item = op.item, let built = TsyncItem.make(item, readOnly: readOnly) {
                updated.append(built)
            }
        }
        return (updated, deleted)
    }
}
