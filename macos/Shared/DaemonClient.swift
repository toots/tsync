import Darwin
import Foundation

// MARK: - Wire types

/// One request. Fields are optional because actions differ in what they need;
/// the daemon reads only the ones its action uses.
struct DaemonRequest: Encodable {
    let action: String
    var ref: String?
    var parentRef: String?
    var name: String?
    var domain: String?
    var path: String?
    var src: String?
    var staging: String?
    var arg: String?
    var target: String?
    var dest: String?
    var offset: Int64?
    var length: Int64?
}

/// An item, as the daemon describes one. `ref`, `parentRef` and `name` build an
/// `NSFileProviderItem`. `key` is the daemon's storage key, for its
/// path-speaking callers, and deliberately unused here: reading it would put
/// knowledge of the key layout back in this process.
struct DaemonItem: Decodable {
    let ref: String
    let parentRef: String
    let name: String
    let kind: String
    let size: Int64
    let mtime: Double
    let etag: String
    let isUploaded: Bool
    let symlinkTarget: String?

    var isDirectory: Bool { kind == "dir" }
    var isSymlink: Bool { kind == "symlink" }
}

/// One change from the journal. A directory keeps its `ref` across a rename, so
/// `ref == srcRef` means the folder moved rather than vanished.
struct DaemonOp: Decodable {
    let op: String
    let ref: String?
    let parentRef: String?
    let name: String?
    let srcRef: String?
}

struct DaemonResponse: Decodable {
    let ok: Bool
    let code: String?
    let error: String?

    let items: [DaemonItem]?
    let ops: [DaemonOp]?
    let stale: Bool?
    let cursor: String?
    let localPath: String?
    let url: String?
    let active: Bool?
    let bytesDownloaded: Int64?
    let totalBytes: Int64?

    /// `status` only.
    let paused: Bool?
    let pendingUploads: Int?
    let pendingDownloads: Int?

    /// The range `fetch_range` served, short of the request at end of file.
    let offset: Int64?
    let length: Int64?

    /// `stat` answers with the item's fields at the top level rather than
    /// nested, so it decodes from this same container and is nil elsewhere.
    let item: DaemonItem?

    private enum CodingKeys: String, CodingKey {
        case ok, code, error, items, ops, stale, cursor, localPath, url
        case active, bytesDownloaded, totalBytes, offset, length
        case paused, pendingUploads, pendingDownloads
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        items = try c.decodeIfPresent([DaemonItem].self, forKey: .items)
        ops = try c.decodeIfPresent([DaemonOp].self, forKey: .ops)
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale)
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
        localPath = try c.decodeIfPresent(String.self, forKey: .localPath)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        active = try c.decodeIfPresent(Bool.self, forKey: .active)
        bytesDownloaded = try c.decodeIfPresent(Int64.self, forKey: .bytesDownloaded)
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes)
        offset = try c.decodeIfPresent(Int64.self, forKey: .offset)
        length = try c.decodeIfPresent(Int64.self, forKey: .length)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused)
        pendingUploads = try c.decodeIfPresent(Int.self, forKey: .pendingUploads)
        pendingDownloads = try c.decodeIfPresent(Int.self, forKey: .pendingDownloads)
        item = try? DaemonItem(from: decoder)
    }
}

/// An event the daemon pushes to a subscriber.
struct DaemonEvent: Decodable {
    let event: String
    let domain: String
    let id: Int
    let ref: String?
    let key: String?
}

// MARK: - Client

/// Talks to the daemon over its unix socket.
///
/// Only this direction works: a sandboxed extension can always reach out, but
/// the OS owns its lifetime, so the daemon cannot rely on connecting in.
///
/// The socket path is injected rather than derived, so a test can point a client
/// at a daemon it started itself.
struct DaemonClient: Sendable {
    let socketPath: String
    let domain: String

    init(socketPath: String, domain: String) {
        self.socketPath = socketPath
        self.domain = domain
    }

    init(domain: String) {
        self.init(socketPath: Config.socketPath, domain: domain)
    }

    // MARK: Transport

    private static func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DaemonError.transport("cannot create socket")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else {
            close(fd)
            throw DaemonError.transport("socket path too long: \(path)")
        }
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    _ = strlcpy($0, cstr, capacity)
                }
            }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw DaemonError.transport("tsync daemon is not running (\(path))")
        }
        return fd
    }

    private static func writeLine(_ fd: Int32, _ data: Data) throws {
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        try payload.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                guard n > 0 else { throw DaemonError.transport("write failed") }
                sent += n
            }
        }
    }

    /// Reads whole lines, holding back a partial one: a response can span reads
    /// and events arrive one per line.
    private final class LineReader {
        private let fd: Int32
        private var buffer = Data()

        init(fd: Int32) { self.fd = fd }

        func next() throws -> String? {
            while true {
                if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    return String(data: line, encoding: .utf8) ?? ""
                }
                var chunk = [UInt8](repeating: 0, count: 8192)
                let n = recv(fd, &chunk, chunk.count, 0)
                if n == 0 { return nil }  // peer closed
                guard n > 0 else { throw DaemonError.transport("read failed") }
                buffer.append(contentsOf: chunk.prefix(n))
            }
        }
    }

    // MARK: Requests

    /// ponytail: a connection per request. The daemon serves many on one now, but
    /// replies carry no request id, so reusing one means serialising against it —
    /// worth a pool only if the connect ever shows up in a profile.
    func send(_ request: DaemonRequest) async throws -> DaemonResponse {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try sendSync(request)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func sendSync(_ request: DaemonRequest) throws -> DaemonResponse {
        var request = request
        if request.domain == nil { request.domain = domain }
        let fd = try Self.connect(to: socketPath)
        defer { close(fd) }
        try Self.writeLine(fd, try JSONEncoder().encode(request))
        // Half-close tells the daemon no more requests are coming, so it
        // finishes and lets go.
        shutdown(fd, SHUT_WR)

        guard let line = try LineReader(fd: fd).next(), !line.isEmpty else {
            throw DaemonError.transport("no response from daemon")
        }
        let response = try JSONDecoder().decode(DaemonResponse.self,
                                                from: Data(line.utf8))
        guard response.ok else {
            throw DaemonError.remote(code: response.code ?? "internal",
                                     message: response.error ?? "unknown error")
        }
        return response
    }

    // MARK: Events

    /// Subscribe to this domain's events, calling `onEvent` for each until the
    /// connection drops. Blocking; run it on its own thread.
    ///
    /// The write half stays open: the daemon reads end-of-input as the subscriber
    /// going away, so half-closing would end the subscription immediately.
    func subscribe(onEvent: (DaemonEvent) -> Void) throws {
        let fd = try Self.connect(to: socketPath)
        defer { close(fd) }
        let request = DaemonRequest(action: "subscribe", domain: domain)
        try Self.writeLine(fd, try JSONEncoder().encode(request))

        let reader = LineReader(fd: fd)
        guard let ack = try reader.next() else {
            throw DaemonError.transport("subscribe: connection closed")
        }
        let response = try JSONDecoder().decode(DaemonResponse.self,
                                                from: Data(ack.utf8))
        guard response.ok else {
            throw DaemonError.remote(code: response.code ?? "internal",
                                     message: response.error ?? "subscribe refused")
        }
        while let line = try reader.next() {
            if line.isEmpty { continue }
            if let event = try? JSONDecoder().decode(DaemonEvent.self,
                                                     from: Data(line.utf8)) {
                onEvent(event)
            }
        }
    }
}

// MARK: - Typed actions

extension DaemonClient {
    func stat(_ ref: String) async throws -> DaemonItem {
        let response = try await send(DaemonRequest(action: "stat", ref: ref))
        guard let item = response.item else {
            throw DaemonError.remote(code: "internal", message: "stat returned no item")
        }
        return item
    }

    func listDir(_ ref: String) async throws -> [DaemonItem] {
        try await send(DaemonRequest(action: "list_dir", ref: ref)).items ?? []
    }

    func listAll(_ ref: String) async throws -> [DaemonItem] {
        try await send(DaemonRequest(action: "list_all", ref: ref)).items ?? []
    }

    func currentCursor() async throws -> String {
        try await send(DaemonRequest(action: "cursor")).cursor ?? ""
    }

    func changesSince(_ anchor: String) async throws -> DaemonResponse {
        try await send(DaemonRequest(action: "changes_since", arg: anchor))
    }

    /// The daemon assembles the file where the system wants it: this process may
    /// not move one into that directory (EPERM, on locally signed and notarised
    /// builds alike).
    func ensureCached(ref: String, destination: String) async throws {
        _ = try await send(DaemonRequest(action: "ensure_cached", ref: ref,
                                         dest: destination))
    }

    /// Write one range into `destination` at that same offset, the rest left
    /// sparse. Returns the range served, short of the request at end of file.
    func fetchRange(ref: String, destination: String,
                    offset: Int64, length: Int64) async throws -> NSRange {
        let response = try await send(DaemonRequest(action: "fetch_range", ref: ref,
                                                    dest: destination,
                                                    offset: offset, length: length))
        guard let served = response.length else {
            throw DaemonError.transport("fetch_range answered no length")
        }
        return NSRange(location: Int(response.offset ?? offset), length: Int(served))
    }

    func downloadProgress(ref: String) async throws -> DaemonResponse {
        try await send(DaemonRequest(action: "download_progress", ref: ref))
    }

    /// Deliberately cheap on the daemon side — no store or backend access — so
    /// it can back a poll.
    func status() async throws -> DaemonResponse {
        try await send(DaemonRequest(action: "status"))
    }

    /// Uploads only: a download runs because something is blocked waiting for
    /// it. Not persisted — a daemon restart resumes.
    func setPaused(_ paused: Bool) async throws {
        _ = try await send(DaemonRequest(action: "pause", arg: paused ? "on" : "off"))
    }

    func create(parentRef: String, name: String) async throws -> DaemonResponse {
        try await send(DaemonRequest(action: "create", parentRef: parentRef, name: name))
    }

    func write(parentRef: String, name: String, staging: String) async throws -> DaemonResponse {
        try await send(DaemonRequest(action: "write", parentRef: parentRef,
                                     name: name, staging: staging))
    }

    func mkdir(parentRef: String, name: String) async throws -> DaemonResponse {
        try await send(DaemonRequest(action: "mkdir", parentRef: parentRef, name: name))
    }

    func symlink(parentRef: String, name: String, target: String) async throws -> DaemonResponse {
        try await send(DaemonRequest(action: "symlink", parentRef: parentRef,
                                     name: name, target: target))
    }

    func rename(ref: String, parentRef: String, name: String) async throws -> DaemonResponse {
        try await send(DaemonRequest(action: "rename", ref: ref,
                                     parentRef: parentRef, name: name))
    }

    func delete(ref: String, isDirectory: Bool) async throws {
        _ = try await send(DaemonRequest(action: isDirectory ? "rmdir" : "delete", ref: ref))
    }

    func share(ref: String) async throws -> String {
        let response = try await send(DaemonRequest(action: "share", ref: ref))
        guard let url = response.url else {
            throw DaemonError.remote(code: "internal", message: "share returned no URL")
        }
        return url
    }
}
