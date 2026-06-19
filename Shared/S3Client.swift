import AsyncHTTPClient
import CryptoKit
import Foundation
import NIOCore
import OSLog
import SotoS3

private let log = os.Logger(subsystem: "com.toots.tsync", category: "S3Client")
private let chunkSize = 8 * 1024 * 1024
private let chunkThreshold = 8 * 1024 * 1024

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
    var base64String: String { Data(self).base64EncodedString() }
}

private extension Insecure.MD5.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

public struct S3Client: Sendable {
    private let s3: S3
    public let awsClient: AWSClient
    private let httpClient: HTTPClient
    public let bucket: String

    public init(bucket: String, region: String, credentials: AWSCredentials) {
        self.bucket = bucket
        let http = HTTPClient(
            eventLoopGroupProvider: .createNew,
            configuration: .init(timeout: .init(connect: .seconds(30), read: .seconds(60)))
        )
        self.httpClient = http
        self.awsClient = AWSClient(
            credentialProvider: .static(accessKeyId: credentials.accessKeyId, secretAccessKey: credentials.secretAccessKey),
            httpClient: http
        )
        self.s3 = S3(client: awsClient, region: SotoCore.Region(rawValue: region))
    }

    public func shutdown() throws {
        try awsClient.syncShutdown()
        try httpClient.syncShutdown()
    }

    public func putEmpty(key: String) async throws {
        _ = try await s3.putObject(.init(
            body: AWSHTTPBody(),
            bucket: bucket,
            contentType: "application/x-directory",
            key: key
        ))
    }

    public func put(key: String, fileURL: URL) async throws {
        let data = try Data(contentsOf: fileURL)
        _ = try await s3.putObject(.init(body: AWSHTTPBody(bytes: data), bucket: bucket, key: key))
    }

    // ponytail: collects full body into memory; use getObjectStreaming for files that exceed RAM
    public func get(key: String, to fileURL: URL) async throws {
        let output = try await s3.getObject(.init(bucket: bucket, key: key))
        let buffer = try await output.body.collect(upTo: 1024 * 1024 * 1024)
        try Data(buffer.readableBytesView).write(to: fileURL)
    }

    public func delete(key: String) async throws {
        _ = try await s3.deleteObject(.init(bucket: bucket, key: key))
    }

    /// Batch-delete up to 1000 keys per S3 request. No-op if keys is empty.
    public func deleteObjects(keys: [String]) async throws {
        guard !keys.isEmpty else { return }
        for batchStart in stride(from: 0, to: keys.count, by: 1000) {
            let batch = Array(keys[batchStart ..< min(batchStart + 1000, keys.count)])
            let objects = batch.map { S3.ObjectIdentifier(key: $0) }
            _ = try await s3.deleteObjects(.init(
                bucket: bucket,
                delete: .init(objects: objects, quiet: true)
            ))
        }
    }

    public func copy(from fromKey: String, to toKey: String) async throws {
        let source = "/\(bucket)/\(fromKey)"
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "/\(bucket)/\(fromKey)"
        _ = try await s3.copyObject(.init(bucket: bucket, copySource: source, key: toKey))
    }

    public func head(key: String) async throws -> (size: Int64, modified: Date?, etag: String?) {
        let out = try await s3.headObject(.init(bucket: bucket, key: key))
        return (out.contentLength ?? 0, out.lastModified, out.eTag)
    }

    /// Returns (commonPrefixes, objectKeys). Handles ListObjectsV2 pagination automatically.
    public func list(prefix: String, delimiter: String? = nil) async throws -> (prefixes: [String], keys: [String]) {
        var prefixes: [String] = []
        var keys: [String] = []
        var token: String? = nil

        repeat {
            let out = try await s3.listObjectsV2(.init(
                bucket: bucket,
                continuationToken: token,
                delimiter: delimiter,
                prefix: prefix
            ))
            prefixes += (out.commonPrefixes ?? []).compactMap(\.prefix)
            keys += (out.contents ?? []).compactMap(\.key)
            token = out.isTruncated == true ? out.nextContinuationToken : nil
        } while token != nil

        return (prefixes, keys)
    }

    public func putChunked(key: String, fileURL: URL, chunkPrefix: String) async throws {
        let sizeRaw = (try FileManager.default.attributesOfItem(atPath: fileURL.path))[.size]
        let size = Int64(sizeRaw as? Int ?? 0)

        guard size > Int64(chunkThreshold) else {
            try await put(key: key, fileURL: fileURL)
            return
        }

        // First pass: compute SHA-256 of each chunk (no bytes retained)
        var entries: [ChunkEntry] = []
        do {
            let fh = try FileHandle(forReadingFrom: fileURL)
            defer { try? fh.close() }
            var index = 0
            while true {
                guard let data = try fh.read(upToCount: chunkSize), !data.isEmpty else { break }
                let sha256 = SHA256.hash(data: data)
                let md5 = Insecure.MD5.hash(data: data)
                entries.append(ChunkEntry(index: index, sha256: sha256.hexString, md5: md5.hexString, size: data.count))
                index += 1
            }
        }

        // Concurrently HEAD all chunks to find which are missing
        let missingSet: Set<String> = try await withThrowingTaskGroup(of: (String, Bool).self) { group in
            for entry in entries {
                group.addTask {
                    let exists = await self.chunkExists(key: chunkPrefix + entry.chunkKey)
                    return (entry.sha256, !exists)
                }
            }
            var missing = Set<String>()
            for try await (sha256, isMissing) in group {
                if isMissing { missing.insert(sha256) }
            }
            return missing
        }

        // Second pass: upload missing chunks in parallel (each task opens its own FileHandle)
        let missingEntries = entries.filter { missingSet.contains($0.sha256) }
        log.info("upload \(key): \(entries.count) chunks, \(missingEntries.count) to upload")
        try await withBoundedConcurrency(missingEntries, maxConcurrent: 8) { entry in
            let fh = try FileHandle(forReadingFrom: fileURL)
            defer { try? fh.close() }
            try fh.seek(toOffset: UInt64(entry.index) * UInt64(chunkSize))
            guard let data = try fh.read(upToCount: chunkSize), !data.isEmpty else { return }
            let digest = SHA256.hash(data: data)
            let chunkKey = chunkPrefix + entry.chunkKey
            log.debug("uploading chunk \(entry.index)/\(entries.count) key=\(chunkKey, privacy: .public)")
            _ = try await self.s3.putObject(.init(
                body: AWSHTTPBody(bytes: data),
                bucket: self.bucket,
                checksumSHA256: digest.base64String,
                key: chunkKey
            ))
        }

        let manifest = ChunkManifest(v: 1, size: size, chunkSize: chunkSize, chunks: entries)
        let manifestData = try JSONEncoder().encode(manifest)
        _ = try await s3.putObject(.init(
            body: AWSHTTPBody(bytes: manifestData),
            bucket: bucket,
            contentType: ChunkManifest.contentType,
            key: key
        ))
    }

    public func getChunked(key: String, to fileURL: URL, chunkPrefix: String) async throws {
        let output = try await s3.getObject(.init(bucket: bucket, key: key))
        let bodyBuffer = try await output.body.collect(upTo: 1024 * 1024 * 1024)
        let body = Data(bodyBuffer.readableBytesView)

        if output.contentType == ChunkManifest.contentType {
            let manifest = try JSONDecoder().decode(ChunkManifest.self, from: body)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            // Pre-allocate full size so concurrent offset writes are safe
            let preallocFH = try FileHandle(forWritingTo: fileURL)
            try preallocFH.truncate(atOffset: UInt64(manifest.size))
            try preallocFH.close()

            log.info("download \(key): \(manifest.chunks.count) chunks")
            try await withBoundedConcurrency(manifest.chunks, maxConcurrent: 8) { (chunk: ChunkEntry) in
                let chunkKey = chunkPrefix + chunk.chunkKey
                log.debug("downloading chunk \(chunk.index)/\(manifest.chunks.count) key=\(chunkKey, privacy: .public)")
                let chunkOutput = try await self.s3.getObject(
                    .init(bucket: self.bucket, key: chunkKey))
                let chunkBuffer = try await chunkOutput.body.collect(upTo: chunkSize + 1)
                let chunkData = Data(chunkBuffer.readableBytesView)
                guard !chunkData.isEmpty else {
                    throw ChunkIntegrityError(index: chunk.index)
                }
                guard SHA256.hash(data: chunkData).hexString == chunk.sha256 else {
                    throw ChunkIntegrityError(index: chunk.index)
                }
                let fh = try FileHandle(forWritingTo: fileURL)
                defer { try? fh.close() }
                try fh.seek(toOffset: UInt64(chunk.index) * UInt64(manifest.chunkSize))
                try fh.write(contentsOf: chunkData)
            }
        } else {
            try body.write(to: fileURL)
        }
    }


    private func chunkExists(key: String) async -> Bool {
        do {
            _ = try await s3.headObject(.init(bucket: bucket, key: key))
            return true
        } catch {
            return false
        }
    }

    /// List objects with size/date metadata (recursive, no delimiter).
    public func listWithMetadata(prefix: String) async throws -> [(key: String, size: Int64, modified: Date?, etag: String?)] {
        var results: [(key: String, size: Int64, modified: Date?, etag: String?)] = []
        var token: String? = nil

        repeat {
            let out = try await s3.listObjectsV2(.init(
                bucket: bucket,
                continuationToken: token,
                prefix: prefix
            ))
            for obj in out.contents ?? [] {
                guard let key = obj.key else { continue }
                results.append((key, obj.size ?? 0, obj.lastModified, obj.eTag))
            }
            token = out.isTruncated == true ? out.nextContinuationToken : nil
        } while token != nil

        return results
    }
}

func withBoundedConcurrency<T: Sendable>(
    _ items: [T], maxConcurrent: Int,
    operation: @escaping @Sendable (T) async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        var inFlight = 0
        for item in items {
            if inFlight >= maxConcurrent { try await group.next(); inFlight -= 1 }
            group.addTask { try await operation(item) }
            inFlight += 1
        }
        try await group.waitForAll()
    }
}
