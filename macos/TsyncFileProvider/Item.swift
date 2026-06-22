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
    var isUploaded: Bool { true }
    let isDownloaded: Bool
    var contentPolicy: NSFileProviderContentPolicy { .downloadLazily }

    init(
        identifier: NSFileProviderItemIdentifier,
        parent: NSFileProviderItemIdentifier,
        filename: String,
        isDirectory: Bool,
        size: Int64? = nil,
        modificationDate: Date? = nil,
        etag: String? = nil,
        isDownloaded: Bool = false
    ) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parent
        self.filename = filename
        self.contentType = isDirectory
            ? .folder
            : UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
        self.documentSize = size.map { NSNumber(value: $0) }
        self.contentModificationDate = modificationDate
        self.capabilities = isDirectory
            ? [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
            : [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsTrashing, .allowsDeleting, .allowsEvicting]
        let versionData = (etag ?? "").data(using: .utf8) ?? Data()
        self.itemVersion = NSFileProviderItemVersion(contentVersion: versionData, metadataVersion: versionData)
        self.isDownloaded = isDownloaded
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

extension TsyncItem {
    /// Parse an S3 key into parent identifier and filename.
    /// e.g. "prefix/domain/Albums/foo.wav" → parent="prefix/domain/Albums/", filename="foo.wav"
    static func parentIdentifier(for s3Key: String, domainPrefix: String) -> NSFileProviderItemIdentifier {
        let components = s3Key.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count > 1 else { return .rootContainer }
        let parentKey = components.dropLast().joined(separator: "/") + "/"
        // If parent IS the domain root, map to .rootContainer
        return parentKey == domainPrefix ? .rootContainer : NSFileProviderItemIdentifier(parentKey)
    }
}
