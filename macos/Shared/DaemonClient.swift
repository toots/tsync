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
    /// Listing: resume after this name, and serve at most this many.
    var after: String?
    var limit: Int?
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

    /// Written only when set, so a live item's row is unchanged. Carried now so
    /// that turning trash on later is a change to how it is used, not to what
    /// the daemon says.
    let trashed: Bool?

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

    /// The whole item, so a batch of changes becomes items without a call each.
    /// Absent for a removal, which has nothing left to describe.
    let item: DaemonItem?

    var isDeletion: Bool { op == "delete" || op == "rmdir" }
}

/// What a row does when clicked. Every case names a domain and a path under it
/// rather than a place on disk: only this process can ask the File Provider
/// where a domain's folder was surfaced, so resolving one is the menu's job.
struct DaemonMenuAction: Decodable {
    struct Target: Decodable {
        let domain: String
        let rel: String
    }

    var openFolder: String?
    var reveal: Target?
    var setPaused: Bool?
    var stats: Bool?
    var quit: Bool?
}

/// One row. A separator carries nothing else; everything else is a label plus
/// whatever of the trimmings it uses.
struct DaemonMenuRow: Decodable {
    var separator: Bool?
    var label: String?
    var enabled: Bool?
    var indent: Int?
    var checked: Bool?
    var submenu: Bool?
    var action: DaemonMenuAction?

    var isSeparator: Bool { separator == true }
}

/// The menu as the daemon decided it: the strings, the icon and the rows all
/// come from one place, shared with the Linux tray, so the two cannot drift.
struct DaemonMenu: Decodable {
    let icon: String
    let tooltip: String

    /// What a submenu holds until the rows it fetches on opening arrive.
    let submenuPlaceholder: [DaemonMenuRow]?
    let rows: [DaemonMenuRow]
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

    /// `menu` only: the whole status menu, decided by the daemon.
    let menu: DaemonMenu?

    /// `menu_stats` only: the stats submenu's rows, with no icon or tooltip
    /// around them since they hang under a row that already has both.
    let rows: [DaemonMenuRow]?

    /// The range `fetch_range` served, short of the request at end of file.
    let offset: Int64?
    let length: Int64?

    /// The item a mutation produced. `stat` answers with the fields at the top
    /// level instead and is read as a `DaemonItem` outright.
    let item: DaemonItem?

    /// `list_dir` and `list_all`: resume the listing after this cursor. Absent
    /// at the end.
    let next: String?

    /// `changes_since` only: another call from `cursor` would answer with more.
    let more: Bool?
}

/// The daemon's verdict on a request, read before the reply is read as
/// anything else.
private struct DaemonVerdict: Decodable {
    let ok: Bool
    let code: String?
    let error: String?
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
        try await send(request, as: DaemonResponse.self)
    }

    /// A reply read as `Reply`, for the actions whose answer is not the common
    /// shape. The daemon's verdict is checked first whatever the shape.
    func send<Reply: Decodable>(_ request: DaemonRequest,
                                as reply: Reply.Type) async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try sendSync(request, as: reply)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func sendSync<Reply: Decodable>(_ request: DaemonRequest,
                                    as reply: Reply.Type) throws -> Reply {
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
        let data = Data(line.utf8)
        let verdict = try JSONDecoder().decode(DaemonVerdict.self, from: data)
        guard verdict.ok else {
            throw DaemonError.remote(code: verdict.code ?? "internal",
                                     message: verdict.error ?? "unknown error")
        }
        return try JSONDecoder().decode(reply, from: data)
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
        try await send(DaemonRequest(action: "stat", ref: ref), as: DaemonItem.self)
    }

    /// One page of a folder, ordered by name. `next` names where to resume and
    /// is nil at the end.
    func listDir(_ ref: String, after: String? = nil, limit: Int? = nil)
        async throws -> (items: [DaemonItem], next: String?) {
        let response = try await send(
            DaemonRequest(action: "list_dir", ref: ref, after: after, limit: limit))
        return (response.items ?? [], response.next)
    }

    /// One page of the whole domain, in one order across folders. `next` is the
    /// cursor to resume from and is nil at the end.
    func listAll(after: String? = nil, limit: Int? = nil)
        async throws -> (items: [DaemonItem], next: String?) {
        let response = try await send(
            DaemonRequest(action: "list_all", after: after, limit: limit))
        return (response.items ?? [], response.next)
    }

    func currentCursor() async throws -> String {
        try await send(DaemonRequest(action: "cursor")).cursor ?? ""
    }

    func changesSince(_ anchor: String, limit: Int? = nil) async throws -> DaemonResponse {
        try await send(DaemonRequest(action: "changes_since", arg: anchor, limit: limit))
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

    /// The whole menu, across every domain this daemon serves — so it is asked
    /// once, not once per domain, and the summary and icon come back decided.
    /// The daemon renders it from the same model the Linux tray links.
    func menu() async throws -> DaemonMenu {
        let response = try await send(DaemonRequest(action: "menu"))
        guard let menu = response.menu else {
            throw DaemonError.transport("daemon returned no menu")
        }
        return menu
    }

    /// The stats submenu's rows, asked for when it opens rather than on the
    /// poll: answering reaches every backend of every domain.
    func menuStats() async throws -> [DaemonMenuRow] {
        let response = try await send(DaemonRequest(action: "menu_stats"))
        guard let rows = response.rows else {
            throw DaemonError.transport("daemon returned no stats rows")
        }
        return rows
    }

    /// Uploads only: a download runs because something is blocked waiting for
    /// it. Not persisted — a daemon restart resumes.
    func setPaused(_ paused: Bool) async throws {
        _ = try await send(DaemonRequest(action: "pause", arg: paused ? "on" : "off"))
    }

    // Each of these answers with the item it produced, in `item`. Nothing has to
    // list the parent afterwards to find what it just made — which a directory
    // forced, its reference being a folder id only the daemon mints.

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
