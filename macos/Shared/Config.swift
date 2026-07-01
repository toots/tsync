import Foundation

public struct DomainConfig: Codable, Sendable {
    public let name: String
    public init(name: String) { self.name = name }
}

public struct Config: Codable, Sendable {
    public let bucket: String
    public let prefix: String
    public let awsRegion: String
    public let versioning: Bool
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

    /// Full S3 key prefix for a domain, e.g. "tsync/Music Production/"
    public func domainPrefix(_ domainName: String) -> String {
        prefix.hasSuffix("/") ? "\(prefix)\(domainName)/" : "\(prefix)/\(domainName)/"
    }

    /// S3 prefix for shared content-addressable chunks
    public func chunkPrefix() -> String {
        prefix.hasSuffix("/") ? "\(prefix).chunks/" : "\(prefix)/.chunks/"
    }

    /// S3 trash prefix for a domain
    public func trashPrefix(_ domainName: String) -> String {
        prefix.hasSuffix("/") ? "\(prefix).trash/\(domainName)/" : "\(prefix)/.trash/\(domainName)/"
    }

    /// S3 journal prefix for a domain
    public func journalPrefix(_ domainName: String) -> String {
        prefix.hasSuffix("/") ? "\(prefix).journal/\(domainName)/" : "\(prefix)/.journal/\(domainName)/"
    }

    /// S3 key for the domain version file (bumped on every mutation)
    public func versionKey(_ domainName: String) -> String {
        prefix.hasSuffix("/") ? "\(prefix).version/\(domainName)" : "\(prefix)/.version/\(domainName)"
    }

    public init(bucket: String, prefix: String, awsRegion: String, versioning: Bool, domains: [DomainConfig]) {
        self.bucket = bucket
        self.prefix = prefix
        self.awsRegion = awsRegion
        self.versioning = versioning
        self.domains = domains
    }
}
