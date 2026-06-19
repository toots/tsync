import Foundation

public struct IPCRequest: Codable, Sendable {
    public let action: String
    public let path: String
    public init(action: String, path: String = "") {
        self.action = action
        self.path = path
    }
}

public struct IPCResponse: Codable, Sendable {
    public let ok: Bool
    public let error: String?
    public init(ok: Bool, error: String? = nil) {
        self.ok = ok
        self.error = error
    }
}

public enum IPC {
    public static var socketPath: String {
        Config.groupContainerURL.appendingPathComponent("tsync.sock").path
    }

    /// Synchronous client call — blocks until TsyncApp responds. For CLI use only.
    public static func send(_ request: IPCRequest) throws -> IPCResponse {
        let path = socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.connectionFailed }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                    _ = strlcpy(cptr, cstr, 104)
                }
            }
        }

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw IPCError.appNotRunning
        }

        let data = try JSONEncoder().encode(request)
        _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, $0.count, 0) }
        shutdown(fd, SHUT_WR)

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { break }
            response.append(contentsOf: buf.prefix(n))
        }

        return try JSONDecoder().decode(IPCResponse.self, from: response)
    }

    public enum IPCError: LocalizedError {
        case connectionFailed
        case appNotRunning

        public var errorDescription: String? {
            switch self {
            case .connectionFailed: "IPC connection failed."
            case .appNotRunning: "TsyncApp is not running. Start it with: open /Applications/TsyncApp.app"
            }
        }
    }
}
