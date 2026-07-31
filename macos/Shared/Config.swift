import Foundation

public struct DomainConfig: Codable, Sendable {
    public let name: String
    public let readOnly: Bool

    enum CodingKeys: String, CodingKey {
        case name, readOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        readOnly = (try? c.decodeIfPresent(Bool.self, forKey: .readOnly)) ?? false
    }
}

/// What this side needs to know: which domains exist, whether each is writable,
/// and where to reach the daemon.
///
/// Deliberately not the storage layout. This used to derive the S3 key prefix
/// for a domain, restating a rule that lives in the daemon's `Conf_parsing` with
/// nothing but a comment holding the two in agreement. Items are named by
/// reference now, so where they are actually stored is the daemon's business.
public struct Config: Codable, Sendable {
    public let domains: [DomainConfig]

    public static let groupID = "group.org.feverdreamtv.tsync"

    public static var groupContainerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/\(groupID)")
    }

    /// Runtime state the daemon owns. Must agree with `Runtime.default_paths` in
    /// `lib/runtime/macos_runtime.ml`.
    public static var dataDirURL: URL {
        groupContainerURL.appendingPathComponent("tsync", isDirectory: true)
    }

    public static var socketPath: String {
        dataDirURL.appendingPathComponent("tsync.sock").path
    }

    public static func load() throws -> Config {
        let url = groupContainerURL.appendingPathComponent("config.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    public func isReadOnly(_ domainName: String) -> Bool {
        domains.first(where: { $0.name == domainName })?.readOnly ?? false
    }

    /// Stamped by the daemon whenever it rebuilds a domain's local mirror — the
    /// only way changes made straight in the store are ever picked up. Nothing
    /// journals those, so no delta can bridge a sync anchor issued beforehand and
    /// every enumerator has to drop its index and re-list. Anchors carry this
    /// token so a mismatch expires them on sight, which still works when the
    /// stamp lands while this extension is not running — as it usually does.
    public static func resyncToken(domain: String) -> String {
        let url = dataDirURL.appendingPathComponent("resync-\(domain)")
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
