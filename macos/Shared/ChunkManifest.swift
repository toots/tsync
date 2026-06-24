import Foundation

public struct ChunkEntry: Codable, Sendable {
    public let index: Int
    public let h1: String
    public let h2: String
    public let size: Int

    public var chunkKey: String { h1 + "-" + h2 }
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
