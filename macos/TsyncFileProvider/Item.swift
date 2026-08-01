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

    /// Download on read, pull remote updates eagerly once a file is not
    /// dataless, evict under disk pressure. A changed `contentVersion` therefore
    /// brings new bytes down on its own, with no explicit eviction.
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

        // No trashing: the domain sets supportsSyncingTrash = false, so there is
        // no container to move anything into. Eviction is covered by
        // contentPolicy above.
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

        // contentVersion is the content hash, falling back to size:mtime for a
        // file with unsynced edits. A directory uses its folder id, constant for
        // its lifetime: children arrive through the change feed, not through the
        // parent's version. Symlink manifests all hash an empty chunk list, so
        // the target is folded in to catch a retarget. metadataVersion also
        // tracks upload state, so a finished upload refreshes the item without
        // re-downloading. Both must be non-empty: FileProvider drops empty
        // version data.
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

    /// The domain root. The system expects its parent to be itself.
    static func rootContainer(displayName: String, readOnly: Bool) -> TsyncItem {
        TsyncItem(identifier: .rootContainer, parent: .rootContainer,
                  filename: displayName, isDirectory: true, readOnly: readOnly)
    }

    /// The daemon supplies the item's reference, its container's and its name,
    /// so nothing here works out where anything lives.
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
            // A directory reports mtime 0 for "no useful date", not the epoch.
            modificationDate: item.mtime > 0
                ? Date(timeIntervalSince1970: item.mtime) : nil,
            etag: item.etag,
            isUploaded: item.isUploaded,
            symlinkTarget: item.symlinkTarget)
    }
}
