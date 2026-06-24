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
    public var journalPrefix: String { config.journalPrefix(domainName) }
    public var versionKey: String { config.versionKey(domainName) }

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
        let (size, modified, etag, contentType) = try await client.head(key: key)
        guard contentType == ChunkManifest.contentType,
              let data = try? await client.getData(key: key),
              let manifest = try? JSONDecoder().decode(ChunkManifest.self, from: data)
        else { return (size, modified, etag) }
        return (manifest.size, modified, etag)
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

    // MARK: Journal

    /// Writes a journal entry and bumps the version file. Fire-and-forget — logs errors, never throws.
    /// Pass a pre-generated entryKey when the key was recorded locally before the S3 op.
    public func writeJournal(ops: [JournalOp], entryKey: String? = nil) async {
        let filename = entryKey ?? Journal.entryKey()
        let key = journalPrefix + filename
        let data = Journal.encode(ops)
        do {
            try await client.putData(key: versionKey, data: Data(filename.utf8), contentType: "text/plain")
            try await client.putData(key: key, data: data, contentType: "application/x-ndjson")
        } catch {
            log.error("writeJournal: \(error, privacy: .public)")
        }
    }

    /// Returns the current version string (latest journal entry filename), or nil if none yet.
    public func fetchVersion() async throws -> String? {
        guard let data = try? await client.getData(key: versionKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replays any journal entries that were written locally but not yet committed to S3
    /// (i.e. the extension crashed between writing the local pending file and completing
    /// the S3 operation). Skips ops where a foreign client made a newer change to the
    /// same key. Call at the start of `tsync sync`.
    public func recoverPendingOps(mountURL: URL) async throws {
        let myUUID = Journal.clientUUID()
        let pending = Journal.localPendingEntries(forUUID: myUUID)
        guard !pending.isEmpty else { return }

        let remoteKeyFilenames = Set(
            try await client.listKeys(prefix: journalPrefix)
                .map { $0.components(separatedBy: "/").last ?? $0 }
        )

        for (entryKey, ops) in pending {
            // Crashed after S3 write, before local delete — just clean up.
            if remoteKeyFilenames.contains(entryKey) {
                Journal.deleteLocalPending(entryKey: entryKey)
                continue
            }

            // Collect keys touched by foreign entries newer than this pending entry.
            let entryMs = Journal.timestampMs(fromFilename: entryKey)
            let hasNewerForeign = remoteKeyFilenames.contains {
                Journal.timestampMs(fromFilename: $0) > entryMs &&
                Journal.clientUUID(fromFilename: $0) != myUUID
            }
            var remotelyModifiedKeys = Set<String>()
            if hasNewerForeign {
                let foreignEntries = try await listJournal(startAfter: journalPrefix + entryKey)
                    .filter { $0.clientUUID != myUUID }
                for entry in foreignEntries {
                    for op in entry.ops {
                        remotelyModifiedKeys.insert(op.key)
                        if let src = op.src { remotelyModifiedKeys.insert(src) }
                    }
                }
            }

            var replayed: [JournalOp] = []
            for op in ops where !remotelyModifiedKeys.contains(op.key) {
                do {
                    switch op.op {
                    case "put":
                        let localFile = mountURL.appendingPathComponent(op.key)
                        guard FileManager.default.fileExists(atPath: localFile.path) else { continue }
                        try await upload(key: key(for: op.key), from: localFile)
                        replayed.append(op)
                    case "delete":
                        try await delete(key: key(for: op.key))
                        replayed.append(op)
                    case "mkdir":
                        try await createDirectory(key: key(for: op.key))
                        replayed.append(op)
                    case "rmdir":
                        try await delete(key: directoryKey(key(for: op.key)))
                        replayed.append(op)
                    case "rename":
                        if let src = op.src {
                            let srcKey = key(for: src)
                            let dstKey = key(for: op.key)
                            if isDirectoryKey(src) {
                                try await renameDirectory(from: directoryKey(srcKey), to: directoryKey(dstKey))
                            } else {
                                try await copy(from: srcKey, to: dstKey)
                                try await delete(key: srcKey)
                            }
                            replayed.append(op)
                        }
                    default: break
                    }
                } catch {
                    log.error("recovery: failed to replay \(op.op, privacy: .public) \(op.key, privacy: .public): \(error, privacy: .public)")
                }
            }

            if !replayed.isEmpty {
                await writeJournal(ops: replayed, entryKey: entryKey)
                log.info("recovery: replayed \(replayed.count, privacy: .public) op(s) from \(entryKey, privacy: .public)")
            }
            Journal.deleteLocalPending(entryKey: entryKey)
        }
    }

    /// Lists journal entries after startAfter (nil = from the beginning).
    public func listJournal(startAfter: String?) async throws -> [JournalEntry] {
        let keys = try await client.listKeys(prefix: journalPrefix, startAfter: startAfter)
        var entries: [JournalEntry] = []
        for key in keys {
            guard let data = try? await client.getData(key: key) else { continue }
            let filename = key.components(separatedBy: "/").last ?? key
            entries.append(JournalEntry(
                s3Key: key,
                clientUUID: Journal.clientUUID(fromFilename: filename),
                timestampMs: Journal.timestampMs(fromFilename: filename),
                ops: Journal.decode(data)
            ))
        }
        return entries
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
