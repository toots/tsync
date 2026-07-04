import FileProvider
import Foundation

public struct IPCRequest: Codable, Sendable {
    public let action: String
    public let path: String?
    public let src: String?
    public let staging: String?
    public let arg: String?

    public init(action: String, path: String? = nil, src: String? = nil,
                staging: String? = nil, arg: String? = nil) {
        self.action = action
        self.path = path
        self.src = src
        self.staging = staging
        self.arg = arg
    }
}

public struct IPCOp: Codable, Sendable {
    public let op: String
    public let key: String
    public let src: String?
}

public struct IPCFileEntry: Codable, Sendable {
    public let key: String
    public let size: Int64
    public let mtime: Double
    public let etag: String?
}

public struct IPCResponse: Codable, Sendable {
    public let ok: Bool
    public let error: String?
    public let size: Int64?
    public let mtime: Double?
    public let etag: String?
    public let localPath: String?
    public let dirs: [String]?
    public let files: [IPCFileEntry]?
    public let isUploaded: Bool?
    public let cursor: String?
    public let ops: [IPCOp]?
    public let stale: Bool?

    public init(ok: Bool, error: String? = nil, size: Int64? = nil, mtime: Double? = nil,
                etag: String? = nil, localPath: String? = nil,
                dirs: [String]? = nil, files: [IPCFileEntry]? = nil,
                isUploaded: Bool? = nil, cursor: String? = nil, ops: [IPCOp]? = nil,
                stale: Bool? = nil) {
        self.ok = ok; self.error = error; self.size = size; self.mtime = mtime
        self.etag = etag; self.localPath = localPath; self.dirs = dirs; self.files = files
        self.isUploaded = isUploaded; self.cursor = cursor; self.ops = ops; self.stale = stale
    }
}

public enum IPC {
    public static var socketPath: String {
        Config.groupContainerURL.appendingPathComponent("tsync/tsync.sock").path
    }

    public enum IPCError: LocalizedError {
        case connectionFailed
        case daemonNotRunning
        case badResponse
        case remoteError(String)

        public var errorDescription: String? {
            switch self {
            case .connectionFailed: "IPC connection failed."
            case .daemonNotRunning: "tsync daemon is not running. Start it with: tsync start"
            case .badResponse: "Unexpected response from daemon."
            case .remoteError(let msg): msg
            }
        }
    }

    // MARK: - Low-level send

    // FileProvider only accepts errors in NSCocoaErrorDomain or NSFileProviderErrorDomain.
    // Returning our own domain makes fileproviderd treat the failure as fatal and cache an
    // empty listing forever. Map to serverUnreachable so it retries once the daemon is up.
    static func fileProviderError(_ error: Error) -> Error {
        switch error {
        case IPCError.connectionFailed, IPCError.daemonNotRunning:
            return NSError(domain: NSFileProviderError.errorDomain,
                           code: NSFileProviderError.serverUnreachable.rawValue)
        default:
            return error
        }
    }

    /// Synchronous send — for CLI use only.
    public static func send(_ request: IPCRequest) throws -> IPCResponse {
        let path = socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.connectionFailed }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, cstr, 104) }
            }
        }

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw IPCError.daemonNotRunning }

        var data = try JSONEncoder().encode(request)
        data.append(UInt8(ascii: "\n"))
        _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, $0.count, 0) }
        shutdown(fd, SHUT_WR)

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { break }
            response.append(contentsOf: buf.prefix(n))
        }

        let decoded = try JSONDecoder().decode(IPCResponse.self, from: response)
        if !decoded.ok, let err = decoded.error { throw IPCError.remoteError(err) }
        return decoded
    }

    /// Async send — for use in the FileProvider extension.
    public static func sendAsync(_ request: IPCRequest) async throws -> IPCResponse {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try send(request)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: - Typed daemon operations

    public static func stat(key: String) async throws -> IPCResponse {
        try await sendAsync(IPCRequest(action: "stat", path: key))
    }

    public static func listDir(prefix: String) async throws -> IPCResponse {
        try await sendAsync(IPCRequest(action: "list_dir", path: prefix))
    }

    public static func listAll(prefix: String) async throws -> IPCResponse {
        try await sendAsync(IPCRequest(action: "list_all", path: prefix))
    }

    public static func currentCursor() async throws -> IPCResponse {
        try await sendAsync(IPCRequest(action: "cursor"))
    }

    public static func changesSince(anchor: String) async throws -> IPCResponse {
        try await sendAsync(IPCRequest(action: "changes_since", arg: anchor))
    }

    public static func ensureCached(key: String) async throws -> IPCResponse {
        try await sendAsync(IPCRequest(action: "ensure_cached", path: key))
    }

    public static func createFile(key: String) async throws -> IPCResponse {
        try await sendAsync(IPCRequest(action: "create", path: key))
    }

    public static func writeFile(key: String, staging: URL) async throws -> IPCResponse {
        try await sendAsync(IPCRequest(action: "write", path: key, staging: staging.path))
    }

    public static func deleteItem(key: String) async throws -> IPCResponse {
        try await sendAsync(IPCRequest(action: "delete", path: key))
    }

    public static func renameItem(src: String, dst: String) async throws -> IPCResponse {
        try await sendAsync(IPCRequest(action: "rename", path: dst, src: src))
    }

    public static func mkdir(key: String) async throws -> IPCResponse {
        try await sendAsync(IPCRequest(action: "mkdir", path: key))
    }

    public static func rmdir(key: String) async throws -> IPCResponse {
        try await sendAsync(IPCRequest(action: "rmdir", path: key))
    }
}
