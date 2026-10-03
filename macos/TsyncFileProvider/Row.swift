import FileProvider
import Foundation

/// Item references as the owner issues them to this host (01 §2.7,
/// file-provider §6.1): `root`, `d:<folder id>` or `i:<file id>`.
enum ItemRef {
    static func isValid(_ ref: String) -> Bool {
        if ref == "root" { return true }
        if ref.hasPrefix("d:") { return isFolderID(String(ref.dropFirst(2))) }
        if ref.hasPrefix("i:") {
            let id = ref.dropFirst(2)
            return id.count == 32 && id.allSatisfy(isHexLower)
        }
        return false
    }

    /// The identifier is the reference verbatim, except the root.
    static func identifier(_ ref: String) -> NSFileProviderItemIdentifier {
        ref == "root" ? .rootContainer : NSFileProviderItemIdentifier(ref)
    }

    static func ref(_ identifier: NSFileProviderItemIdentifier) -> String {
        identifier == .rootContainer ? "root" : identifier.rawValue
    }

    private static func isHexLower(_ c: Character) -> Bool {
        ("0"..."9").contains(c) || ("a"..."f").contains(c)
    }

    /// `hex-id = 1*hexlower [ "-" 1*hexlower ]`; the root's id names the root.
    private static func isFolderID(_ id: String) -> Bool {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        return (parts.count == 1 || parts.count == 2)
            && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(isHexLower) }
    }
}

/// An item row (08 §2.3).
struct Row: Equatable {
    enum Kind: Equatable { case dir, file, symlink }

    let ref: String
    let parentRef: String
    let name: String
    let kind: Kind
    let size: Int64
    let mtime: Double
    let etag: String
    let isUploaded: Bool
    let contentId: String?
    let symlinkTarget: String?
    let readOnly: Bool

    /// Nil for a row whose `ref` or `parentRef` does not parse (§6.1).
    init?(_ json: [String: Any]) {
        guard
            let ref = json["ref"] as? String, ItemRef.isValid(ref),
            let parentRef = json["parentRef"] as? String, ItemRef.isValid(parentRef),
            let name = json["name"] as? String
        else { return nil }
        self.ref = ref
        self.parentRef = parentRef
        self.name = name
        switch json["kind"] as? String {
        case "dir": kind = .dir
        case "symlink": kind = .symlink
        default: kind = .file
        }
        size = (json["size"] as? NSNumber)?.int64Value ?? 0
        mtime = (json["mtime"] as? NSNumber)?.doubleValue ?? 0
        etag = json["etag"] as? String ?? ""
        isUploaded = json["isUploaded"] as? Bool ?? false
        contentId = json["contentId"] as? String
        symlinkTarget = json["symlinkTarget"] as? String
        readOnly = json["readOnly"] as? Bool ?? false
    }

    /// §6.3: changes if and only if the bytes change. A directory's is its
    /// folder id, which its etag carries, constant for its life.
    var contentVersion: Data {
        let version: String
        switch kind {
        case .dir: version = etag
        case .symlink: version = "l:" + (contentId ?? etag)
        case .file: version = contentId ?? etag
        }
        // Never empty: the system drops empty version data.
        return Data((version.isEmpty ? "-" : version).utf8.prefix(128))
    }
}
