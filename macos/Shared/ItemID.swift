import FileProvider

/// How an item is named to the daemon, and the only place that knows the spelling.
///
/// A path is the wrong name for a directory. FileProvider treats an identifier
/// returned from `modifyItem` that differs from the one it passed in as an
/// instruction to *merge* two items, so naming items by path makes every rename
/// a merge — and renaming a folder silently re-identifies everything beneath it,
/// which the system is never told about. Directories therefore carry an id the
/// daemon assigns once and a rename does not touch.
///
/// Files are named by their parent's id and their own leaf. That still changes
/// when a file is renamed or moved, so a file rename is still expressed as a
/// merge — of exactly one item, which the system reconciles. Giving files a
/// stable id of their own would mean changing how they are stored, which is a
/// bigger question than this layer.
///
/// Nothing here spells a storage key. The extension cannot compose one and does
/// not need to: it asks for a container's contents by reference, and creates
/// things by naming a parent and a leaf. Nothing here spells a user's path
/// either, which matters because identifiers reach the system log.
enum ItemID {
    private static let dirPrefix = "d:"
    private static let filePrefix = "f:"

    /// The daemon's name for the domain root. `.rootContainer` is the system's,
    /// and the two have to be kept apart: handing the system anything else for a
    /// top-level item's parent makes it invent a container that does not exist.
    static let rootForm = "root"

    /// Reserved by the daemon for the root folder; it appears as the parent id of
    /// every top-level file.
    static let rootFolderID = ".tsync-root"

    case root
    case directory(folderID: String)
    case file(parentID: String, name: String)

    /// The identifier the system should see.
    var identifier: NSFileProviderItemIdentifier {
        switch self {
        case .root: return .rootContainer
        case .directory(let id): return NSFileProviderItemIdentifier(Self.dirPrefix + id)
        case .file(let parent, let name):
            return NSFileProviderItemIdentifier(Self.filePrefix + parent + "/" + name)
        }
    }

    /// What the daemon should be sent. The system's root identifier is not a
    /// name the daemon knows, so it is translated here rather than at each call.
    static func wire(_ identifier: NSFileProviderItemIdentifier) -> String {
        identifier == .rootContainer ? rootForm : identifier.rawValue
    }

    /// The folder id behind a container identifier, or nil if it names a file.
    static func folderID(of identifier: NSFileProviderItemIdentifier) -> String? {
        if identifier == .rootContainer { return rootFolderID }
        switch parse(identifier.rawValue) {
        case .root: return rootFolderID
        case .directory(let id): return id
        default: return nil
        }
    }

    /// What a file called `name` inside `parent` would be called. Composable
    /// because the scheme belongs to this file — a directory's is not, since only
    /// the daemon can assign a folder id.
    static func file(in parent: NSFileProviderItemIdentifier, named name: String) -> ItemID? {
        guard let id = folderID(of: parent) else { return nil }
        return .file(parentID: id, name: name)
    }

    /// Parse a reference as the daemon spells it. Returns nil for anything that
    /// is not one — including a bare storage key, which the daemon still accepts
    /// from its other callers but never sends here.
    static func parse(_ s: String) -> ItemID? {
        if s == rootForm { return .root }
        if s.hasPrefix(dirPrefix) {
            let id = String(s.dropFirst(dirPrefix.count))
            if id.isEmpty { return nil }
            return id == rootFolderID ? .root : .directory(folderID: id)
        }
        if s.hasPrefix(filePrefix) {
            let rest = s.dropFirst(filePrefix.count)
            // A leaf name cannot contain "/" and no folder id does either, so the
            // first one separates them however odd the name is.
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let parent = String(rest[rest.startIndex..<slash])
            let name = String(rest[rest.index(after: slash)...])
            if parent.isEmpty || name.isEmpty { return nil }
            return .file(parentID: parent, name: name)
        }
        return nil
    }
}
