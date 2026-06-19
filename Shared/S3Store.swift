import Foundation
import OSLog

private let log = os.Logger(subsystem: "com.toots.tsync", category: "S3Store")

/// Bundles S3Client + Config + domainName with domain-aware key construction and S3 operations.
public struct S3Store: Sendable {
    public let client: S3Client
    public let config: Config
    public let domainName: String

    public init(client: S3Client, config: Config, domainName: String) {
        self.client = client
        self.config = config
        self.domainName = domainName
    }

    // MARK: Key helpers

    public var domainPrefix: String { config.domainPrefix(domainName) }
    public var chunkPrefix: String { config.chunkPrefix() }

    public func key(for relativePath: String) -> String { domainPrefix + relativePath }

    public func relativePath(of key: String) -> String {
        key.hasPrefix(domainPrefix) ? String(key.dropFirst(domainPrefix.count)) : key
    }

    public func isDirectoryKey(_ key: String) -> Bool { key.hasSuffix("/") }
    public func directoryKey(_ key: String) -> String { key.hasSuffix("/") ? key : key + "/" }

    public func name(of key: String) -> String {
        key.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/").last ?? key
    }

    // MARK: Domain-aware S3 operations

    public func upload(key: String, from url: URL) async throws {
        log.info("upload: \(key, privacy: .public)")
        try await client.putChunked(key: key, fileURL: url, chunkPrefix: chunkPrefix)
    }

    public func download(key: String, to url: URL) async throws {
        log.info("download: \(key, privacy: .public)")
        try await client.getChunked(key: key, to: url, chunkPrefix: chunkPrefix)
    }

    public func head(key: String) async throws -> (size: Int64, modified: Date?, etag: String?) {
        try await client.head(key: key)
    }

    public func createDirectory(key: String) async throws {
        let dirKey = directoryKey(key)
        log.info("createDirectory: \(dirKey, privacy: .public)")
        try await client.putEmpty(key: dirKey)
    }

    public func listDirectory(prefix: String) async throws -> (dirs: [String], files: [String]) {
        let (subPrefixes, keys) = try await client.list(prefix: prefix, delimiter: "/")
        var dirs = subPrefixes
        for key in keys where key.hasSuffix("/") && !dirs.contains(key) {
            dirs.append(key)
        }
        return (dirs, keys.filter { !$0.hasSuffix("/") })
    }

    public func delete(key: String) async throws {
        log.info("delete: \(key, privacy: .public)")
        if isDirectoryKey(key) {
            let objects = try await client.listWithMetadata(prefix: key)
            guard !objects.isEmpty else { return }
            if config.versioning {
                let files = objects.filter { !$0.key.hasSuffix("/") }
                try await withBoundedConcurrency(files, maxConcurrent: 8) { obj in
                    let trash = Versioning.trashKey(for: obj.key, store: self)
                    try await self.client.copy(from: obj.key, to: trash)
                }
            }
            try await client.deleteObjects(keys: objects.map(\.key))
        } else {
            if config.versioning {
                let trash = Versioning.trashKey(for: key, store: self)
                try await client.copy(from: key, to: trash)
            }
            try await client.delete(key: key)
        }
    }

    public func copy(from fromKey: String, to toKey: String) async throws {
        try await client.copy(from: fromKey, to: toKey)
    }

    /// Recursively moves all S3 objects under oldPrefix to newPrefix.
    /// Used for directory rename — does not create trash copies (it's a move, not a delete).
    public func renameDirectory(from oldPrefix: String, to newPrefix: String) async throws {
        let objects = try await client.listWithMetadata(prefix: oldPrefix)
        log.info("renameDirectory: \(oldPrefix, privacy: .public) → \(newPrefix, privacy: .public) (\(objects.count, privacy: .public) objects)")
        try await withBoundedConcurrency(objects, maxConcurrent: 8) { obj in
            let newKey = newPrefix + String(obj.key.dropFirst(oldPrefix.count))
            try await self.client.copy(from: obj.key, to: newKey)
        }
        try await client.deleteObjects(keys: objects.map(\.key))
    }
}
