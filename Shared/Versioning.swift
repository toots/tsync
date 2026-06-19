import Foundation

public enum Versioning {
    /// Compute the trash key for a given S3 key.
    public static func trashKey(for s3Key: String, store: S3Store) -> String {
        let base = store.config.trashPrefix(store.domainName)
        let relativePath = store.relativePath(of: s3Key)
        return "\(base)\(relativePath)/\(Int(Date().timeIntervalSince1970))"
    }

    /// List all trash entries for a given s3Key. Returns [(trashKey, size, date)].
    public static func history(for s3Key: String, store: S3Store) async throws -> [(key: String, size: Int64, date: Date?)] {
        let base = store.config.trashPrefix(store.domainName)
        let relativePath = store.relativePath(of: s3Key)
        let trashPrefix = "\(base)\(relativePath)/"
        let objects = try await store.client.listWithMetadata(prefix: trashPrefix)
        return objects.map { ($0.key, $0.size, $0.modified) }
    }
}
