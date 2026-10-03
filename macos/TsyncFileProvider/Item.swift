import FileProvider
import UniformTypeIdentifiers

/// A row as the framework's item (§6.2–§6.4). Every field is the owner's;
/// nothing here decides writability, identity or version.
final class Item: NSObject, NSFileProviderItem {
    let row: Row

    init(_ row: Row) {
        self.row = row
    }

    var itemIdentifier: NSFileProviderItemIdentifier { ItemRef.identifier(row.ref) }

    /// The root's parent is itself.
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        row.ref == "root" ? .rootContainer : ItemRef.identifier(row.parentRef)
    }

    var filename: String { row.name }

    var contentType: UTType { Item.contentType(name: row.name, kind: row.kind) }

    /// A directory named like a declared package type takes that type; a
    /// file takes its extension's type, never a directory's (a flat file named
    /// like a package stays a file).
    static func contentType(name: String, kind: Row.Kind) -> UTType {
        let ext = (name as NSString).pathExtension
        switch kind {
        case .symlink:
            return .symbolicLink
        case .dir:
            if !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory),
                type.isDeclared, type.conforms(to: .package)
            {
                return type
            }
            return .folder
        case .file:
            if ext.isEmpty { return .data }
            return UTType(filenameExtension: ext, conformingTo: .data) ?? .data
        }
    }

    /// Exactly the bytes a fetch delivers.
    var documentSize: NSNumber? { row.kind == .dir ? nil : NSNumber(value: row.size) }

    var contentModificationDate: Date? {
        row.mtime > 0 ? Date(timeIntervalSince1970: row.mtime) : nil
    }

    var isUploaded: Bool { row.isUploaded }

    var symlinkTargetPath: String? { row.symlinkTarget }

    /// metadataVersion = contentVersion: the system stores it and otherwise
    /// ignores it.
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: row.contentVersion, metadataVersion: row.contentVersion)
    }

    /// Set on the root, inherited by everything below.
    var contentPolicy: NSFileProviderContentPolicy {
        row.ref == "root" ? .downloadLazily : .inherited
    }

    /// §6.4. No trashing: trash is not implemented.
    var capabilities: NSFileProviderItemCapabilities {
        switch (row.kind, row.readOnly) {
        case (.dir, true): return [.allowsReading, .allowsContentEnumerating]
        case (_, true): return [.allowsReading]
        case (.dir, false):
            return [
                .allowsReading, .allowsContentEnumerating, .allowsAddingSubItems,
                .allowsRenaming, .allowsReparenting, .allowsDeleting,
            ]
        case (.symlink, false):
            return [.allowsReading, .allowsRenaming, .allowsReparenting, .allowsDeleting]
        case (.file, false):
            return [
                .allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting,
                .allowsDeleting,
            ]
        }
    }
}
