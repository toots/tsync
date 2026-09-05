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
/// Deliberately not the storage layout — items are named by reference, so where
/// they are stored is the daemon's business.
public struct Config: Codable, Sendable {
    public let domains: [DomainConfig]

    public static let groupID = "group.org.feverdreamtv.tsync"

    public static var groupContainerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/\(groupID)")
    }

    /// Runtime state the daemon owns. Must agree with `Runtime.default_paths` in
    /// `lib/platform/runtime/macos_runtime.ml`.
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
}
