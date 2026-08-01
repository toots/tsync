import FileProvider

/// How an item is named to the daemon, and the only place that knows the
/// spelling.
///
/// FileProvider reads an identifier returned from `modifyItem` that differs from
/// the one it passed in as an instruction to *merge* two items. Naming a
/// directory by path would therefore make every folder rename a merge, silently
/// re-identifying its whole subtree without telling the system — so directories
/// carry a daemon-assigned id that a rename does not touch.
///
/// Files are named by parent id plus leaf, which still changes on rename: that
/// merge covers exactly one item and the system reconciles it. A stable file id
/// would mean changing how files are stored.
///
/// Nothing here spells a storage key or a user path; identifiers reach the
/// system log.
enum ItemID {
    private static let dirPrefix = "d:"
    private static let filePrefix = "f:"

    /// The daemon's name for the domain root, kept distinct from the system's
    /// `.rootContainer`: any other parent for a top-level item makes the system
    /// invent a container that does not exist.
    static let rootForm = "root"

    /// Reserved by the daemon for the root folder; the parent id of every
    /// top-level file.
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
    /// name it knows, so it is translated here rather than at each call.
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

    /// Composable because the scheme belongs to this file. A directory's is not:
    /// only the daemon assigns folder ids.
    static func file(in parent: NSFileProviderItemIdentifier, named name: String) -> ItemID? {
        guard let id = folderID(of: parent) else { return nil }
        return .file(parentID: id, name: name)
    }

    /// Returns nil for anything that is not a reference, including a bare
    /// storage key: the daemon accepts those from other callers but never sends
    /// one here.
    static func parse(_ s: String) -> ItemID? {
        if s == rootForm { return .root }
        if s.hasPrefix(dirPrefix) {
            let id = String(s.dropFirst(dirPrefix.count))
            if id.isEmpty { return nil }
            return id == rootFolderID ? .root : .directory(folderID: id)
        }
        if s.hasPrefix(filePrefix) {
            let rest = s.dropFirst(filePrefix.count)
            // Neither a leaf name nor a folder id can contain "/", so the first
            // one separates them.
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let parent = String(rest[rest.startIndex..<slash])
            let name = String(rest[rest.index(after: slash)...])
            if parent.isEmpty || name.isEmpty { return nil }
            return .file(parentID: parent, name: name)
        }
        return nil
    }
}
