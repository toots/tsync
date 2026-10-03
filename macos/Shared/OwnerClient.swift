import Darwin
import Foundation

/// Why a request to the owner failed (failure-model §7.2).
/// Built once and only read afterwards, so it crosses threads safely.
enum OwnerFailure: Error, @unchecked Sendable {
    /// The owner's coded refusal; `item` is the occupant an `exists` names.
    case refused(code: String, message: String, item: [String: Any]?)
    /// Nothing accepted the connection: the owner is restarting or not started.
    /// Reported as `unreachable`, which the relay unlatches when the owner
    /// answers again (file-provider §6.10).
    case noOwner(String)
    /// No answer from a connected owner: a broken connection or the client's
    /// own deadline. Treated as `internal`, never `unreachable` or `not_found`.
    case transport(String)
    case cancelled

    /// The code a client acts on: a missing or unknown one reads as `internal`.
    var code: String {
        switch self {
        case .refused(let code, _, _):
            return OwnerFailure.knownCodes.contains(code) ? code : "internal"
        case .noOwner: return "unreachable"
        case .transport: return "internal"
        case .cancelled: return "cancelled"
        }
    }

    var message: String {
        switch self {
        case .refused(_, let message, _): return message
        case .noOwner(let why), .transport(let why): return why
        case .cancelled: return "cancelled"
        }
    }

    static let knownCodes: Set<String> = [
        "not_found", "exists", "not_empty", "read_only", "denied", "invalid", "unreachable",
        "busy", "paused", "internal",
    ]
}

/// Cancels a request from another thread (file-provider §4.3): the socket is shut
/// down under the lock that also guards its close, so a cancel never reaches a
/// reused descriptor, and a request cancelled before it connected never connects.
final class Cancellation {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false

    var isCancelled: Bool { locked { cancelled } }

    func cancel() {
        locked {
            cancelled = true
            if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
        }
    }

    fileprivate func adopt(_ fd: Int32) -> Bool {
        locked {
            if cancelled { return false }
            self.fd = fd
            return true
        }
    }

    fileprivate func release() {
        locked {
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// The owner's request socket, one connection per request (file-provider §4.3).
/// Every call blocks its thread: callers keep it off framework callback queues.
enum OwnerClient {
    /// failure-model §8.3: REQUEST_DEADLINE + CLIENT_DEADLINE_MARGIN.
    static let requestDeadline: TimeInterval = 35
    static let livenessInterval: TimeInterval = 10
    static let livenessDeadline: TimeInterval = 5

    /// One request; an ordinary one is abandoned at `deadline`.
    static func call(
        _ request: [String: Any], deadline: TimeInterval = requestDeadline,
        cancellation: Cancellation = Cancellation(), socketPath: String = Tsync.socketPath
    ) throws -> [String: Any] {
        let reply = try exchange(
            request, deadline: Date().addingTimeInterval(deadline),
            cancellation: cancellation, socketPath: socketPath)
        return try checked(reply)
    }

    /// A bulk request (failure-model §8.2): no total deadline, but abandoned
    /// when a liveness probe on another connection misses.
    static func bulk(
        _ request: [String: Any], cancellation: Cancellation = Cancellation(),
        socketPath: String = Tsync.socketPath
    ) throws -> [String: Any] {
        let done = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error> = .failure(OwnerFailure.cancelled)
        Thread.detachNewThread {
            result = Result {
                try exchange(
                    request, deadline: .distantFuture, cancellation: cancellation,
                    socketPath: socketPath)
            }
            done.signal()
        }
        while done.wait(timeout: .now() + livenessInterval) == .timedOut {
            if cancellation.isCancelled { continue }
            do {
                _ = try call(["action": "ping"], deadline: livenessDeadline, socketPath: socketPath)
            } catch {
                cancellation.cancel()
                done.wait()
                throw OwnerFailure.transport("the owner stopped answering")
            }
        }
        return try checked(result.get())
    }

    private static func checked(_ reply: [String: Any]) throws -> [String: Any] {
        if reply["ok"] as? Bool == true { return reply }
        throw OwnerFailure.refused(
            code: reply["code"] as? String ?? "internal",
            message: reply["error"] as? String ?? "the owner refused the request",
            item: reply["item"] as? [String: Any])
    }

    private static func exchange(
        _ request: [String: Any], deadline: Date, cancellation: Cancellation, socketPath: String
    ) throws -> [String: Any] {
        let line = try JSONSerialization.data(withJSONObject: request) + Data([0x0a])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OwnerFailure.transport(errnoText("socket")) }
        guard cancellation.adopt(fd) else {
            Darwin.close(fd)
            throw OwnerFailure.cancelled
        }
        defer { cancellation.release() }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        try connect(fd, socketPath, cancellation)
        try write(fd, line, deadline, cancellation)
        Darwin.shutdown(fd, SHUT_WR)
        let bytes = try readLine(fd, deadline, cancellation)
        // A name that is not UTF-8 costs that name, not the reply.
        let text = String(decoding: bytes, as: UTF8.self)
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
            let reply = object as? [String: Any]
        else { throw OwnerFailure.transport("the owner's reply is not a JSON object") }
        return reply
    }

    private static func connect(_ fd: Int32, _ path: String, _ c: Cancellation) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw OwnerFailure.transport("the socket path is longer than \(capacity - 1) bytes")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes + [0])
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        if c.isCancelled { throw OwnerFailure.cancelled }
        if status != 0 { throw OwnerFailure.noOwner(errnoText("no owner at \(path)")) }
    }

    private static func wait(
        _ fd: Int32, _ events: Int16, _ deadline: Date, _ c: Cancellation
    ) throws {
        while true {
            if c.isCancelled { throw OwnerFailure.cancelled }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw OwnerFailure.transport("the owner did not answer in time") }
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let ms = Int32(min(remaining, 3600) * 1000)
            let n = poll(&pfd, 1, max(ms, 1))
            if n > 0 { return }
            if n < 0 && errno != EINTR { throw OwnerFailure.transport(errnoText("poll")) }
        }
    }

    private static func write(_ fd: Int32, _ data: Data, _ deadline: Date, _ c: Cancellation)
        throws
    {
        var offset = 0
        while offset < data.count {
            try wait(fd, Int16(POLLOUT), deadline, c)
            let n = data.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + offset, data.count - offset)
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                if c.isCancelled { throw OwnerFailure.cancelled }
                throw OwnerFailure.transport(errnoText("write"))
            }
            offset += n
        }
    }

    private static func readLine(_ fd: Int32, _ deadline: Date, _ c: Cancellation) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let newline = buffer.firstIndex(of: 0x0a) {
                return buffer.prefix(upTo: newline)
            }
            try wait(fd, Int16(POLLIN), deadline, c)
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                if c.isCancelled { throw OwnerFailure.cancelled }
                if !buffer.isEmpty { return buffer }
                throw OwnerFailure.transport("the owner closed the connection")
            } else if errno != EINTR && errno != EAGAIN {
                if c.isCancelled { throw OwnerFailure.cancelled }
                throw OwnerFailure.transport(errnoText("read"))
            }
        }
    }

    private static func errnoText(_ what: String) -> String {
        "\(what): \(String(cString: strerror(errno)))"
    }
}

/// A subscription (file-provider §8.1): a connection that stays open and
/// carries one event per line after the acknowledgement.
final class Subscription {
    private let fd: Int32
    private var buffer = Data()

    /// Connects, subscribes and reads the acknowledgement. On failure the
    /// descriptor is closed by `deinit` alone: a throwing initializer still
    /// runs it, and a second close could hit a reused descriptor.
    init(request: [String: Any], socketPath: String = Tsync.socketPath) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OwnerFailure.transport("socket") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw OwnerFailure.transport("the socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard status == 0 else { throw OwnerFailure.noOwner("no owner") }
        let line = try JSONSerialization.data(withJSONObject: request) + Data([0x0a])
        let written = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, line.count) }
        guard written == line.count, let ack = next(), ack["ok"] as? Bool == true else {
            throw OwnerFailure.transport("the subscription was not acknowledged")
        }
    }

    /// The next line, or nil once the connection ends.
    func next() -> [String: Any]? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                let text = String(decoding: line, as: UTF8.self)
                if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
                    let event = object as? [String: Any]
                {
                    return event
                }
                continue
            }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return nil
            }
        }
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }
}
