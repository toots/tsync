import Foundation

public struct JournalOp: Codable, Sendable {
    public let op: String
    public let key: String
    public let src: String?
    public let size: Int64?

    public init(op: String, key: String, src: String? = nil, size: Int64? = nil) {
        self.op = op
        self.key = key
        self.src = src
        self.size = size
    }
}

public struct JournalEntry: Sendable {
    public let s3Key: String
    public let clientUUID: String
    public let timestampMs: Int64
    public let ops: [JournalOp]
}

public enum Journal {
    private static let uuidFile = "client-uuid"

    /// Returns the persistent client UUID, generating one on first call.
    public static func clientUUID() -> String {
        let url = Config.groupContainerURL.appendingPathComponent(uuidFile)
        if let v = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        let id = UUID().uuidString
        try? id.write(to: url, atomically: true, encoding: .utf8)
        return id
    }

    /// Returns a new journal entry filename: "<13-digit-ms>-<client-uuid>".
    public static func entryKey() -> String {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        return String(format: "%013lld", ms) + "-" + clientUUID()
    }

    /// Extracts timestamp (ms) from a journal entry filename.
    public static func timestampMs(fromFilename filename: String) -> Int64 {
        Int64(filename.prefix(13)) ?? 0
    }

    /// Extracts client UUID from a journal entry filename.
    public static func clientUUID(fromFilename filename: String) -> String {
        filename.count > 14 ? String(filename.dropFirst(14)) : ""
    }

    // MARK: - Local pending journal (WAL commit marker)

    private static var pendingDir: URL {
        let dir = Config.groupContainerURL.appendingPathComponent("journal-pending")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes ops to a local pending file before the S3 operation. The file's
    /// presence means the operation is not yet committed.
    public static func writeLocalPending(ops: [JournalOp], entryKey: String) {
        try? encode(ops).write(to: pendingDir.appendingPathComponent(entryKey))
    }

    /// Deletes the local pending file — call after S3 journal write succeeds.
    public static func deleteLocalPending(entryKey: String) {
        try? FileManager.default.removeItem(at: pendingDir.appendingPathComponent(entryKey))
    }

    /// Returns all uncommitted pending entries for the given UUID, sorted chronologically.
    public static func localPendingEntries(forUUID uuid: String) -> [(entryKey: String, ops: [JournalOp])] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: pendingDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .map(\.lastPathComponent)
            .filter { clientUUID(fromFilename: $0) == uuid }
            .sorted()
            .compactMap { filename in
                guard let data = try? Data(contentsOf: pendingDir.appendingPathComponent(filename)) else { return nil }
                let ops = decode(data)
                return ops.isEmpty ? nil : (entryKey: filename, ops: ops)
            }
    }

    /// Encodes ops to NDJSON.
    public static func encode(_ ops: [JournalOp]) -> Data {
        let encoder = JSONEncoder()
        let lines = ops.compactMap { try? String(data: encoder.encode($0), encoding: .utf8) }
        return (lines.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
    }

    /// Decodes NDJSON, silently skipping unrecognized lines.
    public static func decode(_ data: Data) -> [JournalOp] {
        guard let str = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return str.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            try? decoder.decode(JournalOp.self, from: Data($0.utf8))
        }
    }
}
