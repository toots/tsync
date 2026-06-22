import FileProvider
import Foundation
import OSLog

private let log = Logger(subsystem: "com.toots.tsync", category: "IPCServer")

final class IPCServer: @unchecked Sendable {
    private var serverFD: Int32 = -1

    func start() {
        let path = IPC.socketPath
        try? FileManager.default.removeItem(atPath: path)

        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { log.error("socket() failed"); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                    _ = strlcpy(cptr, cstr, 104)
                }
            }
        }

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { log.error("bind() failed: \(errno)"); return }
        guard listen(serverFD, 5) == 0 else { log.error("listen() failed"); return }

        log.info("IPC server listening")
        Thread.detachNewThread { self.acceptLoop() }
    }

    func stop() {
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        try? FileManager.default.removeItem(atPath: IPC.socketPath)
    }

    private func acceptLoop() {
        while serverFD >= 0 {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else { continue }
            Thread.detachNewThread { self.handleClient(clientFD) }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { break }
            data.append(contentsOf: buf.prefix(n))
        }

        guard let request = try? JSONDecoder().decode(IPCRequest.self, from: data) else {
            respond(fd, IPCResponse(ok: false, error: "invalid request"))
            return
        }

        let sema = DispatchSemaphore(value: 0)
        var response = IPCResponse(ok: false, error: "unknown error")
        Task {
            do {
                switch request.action {
                case "evict":
                    try await evict(path: request.path)
                    response = IPCResponse(ok: true)
                case "restore":
                    try await restore(path: request.path)
                    response = IPCResponse(ok: true)
                default:
                    response = IPCResponse(ok: false, error: "unknown action: \(request.action)")
                }
            } catch {
                let ns = error as NSError
                response = IPCResponse(ok: false, error: "\(error.localizedDescription) [domain=\(ns.domain) code=\(ns.code) underlying=\(ns.userInfo[NSUnderlyingErrorKey] as? NSError)]")
            }
            sema.signal()
        }
        sema.wait()
        respond(fd, response)
    }

    private func respond(_ fd: Int32, _ response: IPCResponse) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        _ = data.withUnsafeBytes { send(fd, $0.baseAddress!, $0.count, 0) }
    }

    // MARK: - FileProvider operations

    private func evict(path: String) async throws {
        let (itemId, manager) = try await fpManager(for: URL(filePath: path))
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            manager.evictItem(identifier: itemId) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    private func restore(path: String) async throws {
        let (itemId, manager) = try await fpManager(for: URL(filePath: path))
        try await manager.requestDownloadForItem(withIdentifier: itemId)
    }

    private func fpManager(for url: URL) async throws -> (NSFileProviderItemIdentifier, NSFileProviderManager) {
        let (itemId, domainId) = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<(NSFileProviderItemIdentifier, NSFileProviderDomainIdentifier), Error>) in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { itemId, domainId, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: (itemId!, domainId!)) }
            }
        }
        let domains = try await NSFileProviderManager.domains()
        guard let domain = domains.first(where: { $0.identifier == domainId }),
              let manager = NSFileProviderManager(for: domain) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return (itemId, manager)
    }
}
