import FileProvider
import Foundation

/// ios.md §5.4: a domain's owner, reached through its File Provider
/// extension's service, one connection per domain kept while this process
/// runs. Every call blocks its thread: callers keep it off the main queue.
enum OwnerClient {
    /// ios.md §5.4 `service_deadline`.
    static let deadline: TimeInterval = 30

    private static let lock = NSLock()
    private static var connections: [String: NSXPCConnection] = [:]

    /// One request naming its domain (`domain`). A bulk action waits for its
    /// reply until the connection ends; any other gives up at the deadline.
    static func call(_ request: [String: Any], bulk: Bool = false) throws -> [String: Any] {
        guard let domain = request["domain"] as? String else {
            throw OwnerFailure.transport("the request names no domain")
        }
        let connection = try connect(domain)
        guard let token = Service.token(create: false) else {
            throw OwnerFailure.noOwner("the extension has not served yet")
        }
        let json = try JSONSerialization.data(withJSONObject: request)
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<Data, OwnerFailure> = .failure(.noOwner("\(domain) did not answer"))
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            forget(domain, connection)
            done.signal()
        } as? OwnerService
        guard let proxy else { throw OwnerFailure.transport("the service has no owner interface") }
        proxy.request(token, json) { reply in
            outcome = .success(reply)
            done.signal()
        }
        if done.wait(timeout: bulk ? .distantFuture : .now() + deadline) == .timedOut {
            throw OwnerFailure.noOwner("\(domain) did not answer in time")
        }
        let reply = try outcome.get()
        guard let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else {
            throw OwnerFailure.transport("the owner's reply is not a JSON object")
        }
        return try OwnerFailure.checked(object)
    }

    private static func connect(_ domain: String) throws -> NSXPCConnection {
        lock.lock()
        let kept = connections[domain]
        lock.unlock()
        if let kept { return kept }
        let manager = try manager(domain)
        let service = try wait { done in
            manager.getService(named: Service.name, for: .rootContainer) { service, error in
                done(service.map(Result.success) ?? .failure(error ?? OwnerFailure.noOwner("no service")))
            }
        }
        let connection = try wait { done in
            service.getFileProviderConnection { connection, error in
                done(connection.map(Result.success) ?? .failure(error ?? OwnerFailure.noOwner("no connection")))
            }
        }
        connection.remoteObjectInterface = Service.interface
        connection.invalidationHandler = { [weak connection] in
            if let connection { forget(domain, connection) }
        }
        connection.resume()
        lock.lock()
        connections[domain] = connection
        lock.unlock()
        return connection
    }

    /// The framework's domain of a display name; turned off in Files, no
    /// extension serves it.
    private static func manager(_ name: String) throws -> NSFileProviderManager {
        let domains = try wait { done in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                done(error.map(Result.failure) ?? .success(domains))
            }
        }
        guard let domain = domains.first(where: { $0.displayName == name }) else {
            throw OwnerFailure.noOwner("\(name) is not registered")
        }
        if !domain.userEnabled { throw OwnerFailure.turnedOff }
        guard let manager = NSFileProviderManager(for: domain) else {
            throw OwnerFailure.noOwner("\(name) has no manager")
        }
        return manager
    }

    private static func forget(_ domain: String, _ connection: NSXPCConnection) {
        lock.lock()
        if connections[domain] === connection { connections[domain] = nil }
        lock.unlock()
    }

    /// A completion-handler call, waited for up to the deadline.
    private static func wait<T>(_ call: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<T, Error> = .failure(OwnerFailure.noOwner("the framework did not answer"))
        call { result in
            outcome = result
            done.signal()
        }
        if done.wait(timeout: .now() + deadline) == .timedOut {
            throw OwnerFailure.noOwner("the framework did not answer in time")
        }
        do {
            return try outcome.get()
        } catch let failure as OwnerFailure {
            throw failure
        } catch {
            throw OwnerFailure.noOwner(error.localizedDescription)
        }
    }
}

/// The owner's sentence wherever a failure is shown.
extension OwnerFailure: LocalizedError {
    var errorDescription: String? { message }
}
