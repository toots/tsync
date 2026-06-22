import Foundation

public struct ChunkEntry: Codable, Sendable {
    public let index: Int
    public let sha256: String
    public let md5: String
    public let size: Int

    public var chunkKey: String { sha256 + "-" + md5 }
}

public struct ChunkManifest: Codable, Sendable {
    public static let contentType = "application/x-tsync-manifest+json"
    public let v: Int
    public let size: Int64
    public let chunkSize: Int
    public let chunks: [ChunkEntry]
}

public struct ChunkIntegrityError: LocalizedError {
    public let index: Int
    public var errorDescription: String? { "Chunk \(index) integrity check failed" }
}
