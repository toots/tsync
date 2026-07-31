import FileProvider
import UniformTypeIdentifiers

final class TsyncItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let capabilities: NSFileProviderItemCapabilities
    let itemVersion: NSFileProviderItemVersion
    let isUploaded: Bool
    let symlinkTargetPath: String?

    /// Download when read; download remote updates eagerly once a file is not
    /// dataless; allow eviction under disk pressure. This is what makes an
    /// explicit eviction on a content change unnecessary — a changed
    /// `contentVersion` already brings the new bytes down by itself.
    var contentPolicy: NSFileProviderContentPolicy { .downloadLazily }

    init(
        identifier: NSFileProviderItemIdentifier,
        parent: NSFileProviderItemIdentifier,
        filename: String,
        isDirectory: Bool,
        readOnly: Bool,
        size: Int64? = nil,
        modificationDate: Date? = nil,
        etag: String = "",
        isUploaded: Bool = true,
        symlinkTarget: String? = nil
    ) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parent
        self.filename = filename
        self.symlinkTargetPath = symlinkTarget
        self.contentType = isDirectory
            ? .folder
            : symlinkTarget != nil
            ? .symbolicLink
            : UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
        self.documentSize = size.map { NSNumber(value: $0) }
        self.contentModificationDate = modificationDate

        // Trashing is not offered: the domain is registered with
        // supportsSyncingTrash = false, so there is no trash container to move
        // anything into. `allowsEvicting` is gone too — deprecated since macOS 13
        // and superseded by contentPolicy above.
        if readOnly {
            self.capabilities = isDirectory
                ? [.allowsReading, .allowsContentEnumerating]
                : [.allowsReading]
        } else if isDirectory {
            self.capabilities = [.allowsReading, .allowsContentEnumerating,
                                 .allowsAddingSubItems, .allowsRenaming,
                                 .allowsReparenting, .allowsDeleting]
        } else if symlinkTarget != nil {
            self.capabilities = [.allowsReading, .allowsRenaming,
                                 .allowsReparenting, .allowsDeleting]
        } else {
            self.capabilities = [.allowsReading, .allowsWriting, .allowsRenaming,
                                 .allowsReparenting, .allowsDeleting]
        }

        // contentVersion is the file's content hash. A file with unsynced edits
        // has no clean hash, so it falls back to size:mtime. A directory's etag is
        // its own folder id, which never changes while it exists — the parent's
        // version says nothing about what is inside it, and what is inside
        // arrives through the change feed. Symlink manifests all share one hash
        // (of an empty chunk list), so the target is folded in to notice a
        // retarget. metadataVersion additionally tracks upload state, so an
        // upload completing refreshes the item without re-downloading it. Both
        // must be non-empty: FileProvider drops empty version data.
        var content = etag.isEmpty
            ? "\(size ?? 0):\(modificationDate?.timeIntervalSince1970 ?? 0)"
            : etag
        if let symlinkTarget { content += ":\(symlinkTarget)" }
        let metadata = "\(content):\(isUploaded ? 1 : 0)"
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: Data(content.utf8),
            metadataVersion: Data(metadata.utf8))
        self.isUploaded = isUploaded
    }

    /// The domain root. Its parent is itself, which is what the system expects.
    static func rootContainer(displayName: String, readOnly: Bool) -> TsyncItem {
        TsyncItem(identifier: .rootContainer, parent: .rootContainer,
                  filename: displayName, isDirectory: true, readOnly: readOnly)
    }

    /// Build an item from what the daemon said about it. The daemon supplies the
    /// item's own reference, its container's, and its name, so nothing here has
    /// to work out where anything lives.
    static func make(_ item: DaemonItem, readOnly: Bool) -> TsyncItem? {
        guard let id = ItemID.parse(item.ref),
              let parent = ItemID.parse(item.parentRef)
        else { return nil }
        return TsyncItem(
            identifier: id.identifier,
            parent: parent.identifier,
            filename: item.name,
            isDirectory: item.isDirectory,
            readOnly: readOnly,
            size: item.size,
            // A directory reports mtime 0, meaning "no useful date" rather than
            // the epoch; showing 1970 in Finder would be worse than showing none.
            modificationDate: item.mtime > 0
                ? Date(timeIntervalSince1970: item.mtime) : nil,
            etag: item.etag,
            isUploaded: item.isUploaded,
            symlinkTarget: item.symlinkTarget)
    }
}
