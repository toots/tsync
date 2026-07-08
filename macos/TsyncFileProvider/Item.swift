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
    let isDownloaded: Bool
    let symlinkTargetPath: String?
    var contentPolicy: NSFileProviderContentPolicy { .downloadLazily }

    init(
        identifier: NSFileProviderItemIdentifier,
        parent: NSFileProviderItemIdentifier,
        filename: String,
        isDirectory: Bool,
        size: Int64? = nil,
        modificationDate: Date? = nil,
        etag: String? = nil,
        isDownloaded: Bool = false,
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
        self.capabilities = isDirectory
            ? [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
            : symlinkTarget != nil
            ? [.allowsReading, .allowsRenaming, .allowsReparenting, .allowsTrashing, .allowsDeleting]
            : [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsTrashing, .allowsDeleting, .allowsEvicting]
        // contentVersion is the file's content hash (Manifest.h1). A dirty file has no clean
        // hash, so fall back to size:mtime there. Symlink manifests all share the same fixed
        // h1 (hash of an empty chunk list), so fold the target in to detect retargeting.
        // metadataVersion additionally tracks upload state, so a completing upload refreshes
        // the item without a content re-download. Both are non-empty by construction
        // (FileProvider drops empty version data).
        var content = etag.flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(size ?? 0):\(modificationDate?.timeIntervalSince1970 ?? 0)"
        if let symlinkTarget { content += ":\(symlinkTarget)" }
        let metadata = "\(content):\(isUploaded ? 1 : 0)"
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: Data(content.utf8),
            metadataVersion: Data(metadata.utf8))
        self.isDownloaded = isDownloaded
        self.isUploaded = isUploaded
    }

    /// Synthetic root container item.
    static func rootContainer(displayName: String) -> TsyncItem {
        TsyncItem(
            identifier: .rootContainer,
            parent: .rootContainer,
            filename: displayName,
            isDirectory: true
        )
    }
}

/// Single source of truth for the item-identifier ⇄ storage-key mapping.
///
/// Invariant enforced here and nowhere else: an item's identifier *is* its full storage
/// key; directory keys end in "/"; the domain-prefix key is the root container. Everything
/// that turns a key into an item (enumeration, change feed, create/modify) goes through this
/// so a given path always resolves to exactly one identity.
enum ItemID {
    static func identifier(forKey key: String, domainPrefix: String) -> NSFileProviderItemIdentifier {
        key == domainPrefix ? .rootContainer : NSFileProviderItemIdentifier(key)
    }

    /// The storage key an identifier points at (directories end in "/").
    static func key(for id: NSFileProviderItemIdentifier, domainPrefix: String) -> String {
        id == .rootContainer ? domainPrefix : id.rawValue
    }

    static func parent(ofKey key: String, domainPrefix: String) -> NSFileProviderItemIdentifier {
        let body = key.hasSuffix("/") ? String(key.dropLast()) : key
        guard let slash = body.lastIndex(of: "/") else { return .rootContainer }
        return identifier(forKey: String(body[...slash]), domainPrefix: domainPrefix)
    }

    static func filename(ofKey key: String) -> String {
        let body = key.hasSuffix("/") ? String(key.dropLast()) : key
        return body.split(separator: "/").last.map(String.init) ?? body
    }
}

extension TsyncItem {
    /// Build an item straight from its storage key — the only supported way to construct a
    /// non-root item. Directory-ness, identifier, parent, and filename all follow from the key.
    static func make(key: String, domainPrefix: String,
                     size: Int64? = nil, modificationDate: Date? = nil,
                     etag: String? = nil, isDownloaded: Bool = false,
                     isUploaded: Bool = true, symlinkTarget: String? = nil) -> TsyncItem {
        TsyncItem(identifier: ItemID.identifier(forKey: key, domainPrefix: domainPrefix),
                  parent: ItemID.parent(ofKey: key, domainPrefix: domainPrefix),
                  filename: ItemID.filename(ofKey: key),
                  isDirectory: key.hasSuffix("/"),
                  size: size, modificationDate: modificationDate, etag: etag,
                  isDownloaded: isDownloaded, isUploaded: isUploaded,
                  symlinkTarget: symlinkTarget)
    }
}
