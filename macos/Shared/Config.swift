import Foundation

public struct DomainConfig: Codable, Sendable {
    public let name: String
    public let prefix: String
    public let readOnly: Bool

    enum CodingKeys: String, CodingKey {
        case name, prefix
        case readOnly = "readOnly"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        prefix = try c.decode(String.self, forKey: .prefix)
        readOnly = (try? c.decodeIfPresent(Bool.self, forKey: .readOnly)) ?? false
    }
}

public struct Config: Codable, Sendable {
    public let domains: [DomainConfig]

    public static let groupID = "group.com.toots.tsync"

    public static var groupContainerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/\(groupID)")
    }

    public static func load() throws -> Config {
        let url = groupContainerURL.appendingPathComponent("config.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    public func isReadOnly(_ domainName: String) -> Bool {
        domains.first(where: { $0.name == domainName })?.readOnly ?? false
    }

    /// Full S3 key prefix for a domain, e.g. "tsync/music-production/"
    public func domainPrefix(_ domainName: String) -> String {
        let p = domains.first(where: { $0.name == domainName })?.prefix ?? ""
        return p.hasSuffix("/") ? "\(p)\(domainName)/" : "\(p)/\(domainName)/"
    }
}
