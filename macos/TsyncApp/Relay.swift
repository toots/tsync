import FileProvider
import Foundation

/// §8.2: the app's one subscription to the owner, relaying its events to the
/// framework. Events are hints: every acknowledgement re-signals everything,
/// since nothing missed is replayed.
final class Relay {
    /// §13 relay_backoff_min / relay_backoff_max / relay_backoff_reset.
    static let backoffMin: TimeInterval = 1
    static let backoffMax: TimeInterval = 30
    static let backoffReset: TimeInterval = 30

    private let reconciler: Reconciler
    private let lock = NSLock()
    private var domains: [String: NSFileProviderDomain] = [:]

    init(reconciler: Reconciler) {
        self.reconciler = reconciler
    }

    /// The registered domains, by display name, as the last pass left them.
    func update(_ registered: [NSFileProviderDomain]) {
        lock.lock()
        domains = Dictionary(uniqueKeysWithValues: registered.map { ($0.displayName, $0) })
        lock.unlock()
    }

    private func registered() -> [NSFileProviderDomain] {
        lock.lock()
        defer { lock.unlock() }
        return Array(domains.values)
    }

    private func registered(_ name: String) -> NSFileProviderDomain? {
        lock.lock()
        defer { lock.unlock() }
        return domains[name]
    }

    func start() {
        Thread.detachNewThread { self.run() }
    }

    /// The relay never gives up. The backoff resets only after a connection
    /// lived long enough: a crash-looping owner must not cost a working-set
    /// enumeration per second.
    private func run() {
        var backoff = Self.backoffMin
        while true {
            let started = Date()
            if let subscription = try? Subscription(request: ["action": "subscribe"]) {
                acknowledged()
                while let event = subscription.next() {
                    handle(event)
                }
            }
            if Date().timeIntervalSince(started) >= Self.backoffReset {
                backoff = Self.backoffMin
            }
            Thread.sleep(forTimeInterval: backoff)
            backoff = min(backoff * 2, Self.backoffMax)
        }
    }

    /// A configuration change takes effect here once the owner restarts.
    private func acknowledged() {
        reconciler.request()
        for domain in registered() {
            signal(domain, resolving: [.serverUnreachable, .cannotSynchronize])
        }
    }

    private func handle(_ event: [String: Any]) {
        guard let name = event["domain"] as? String else { return }
        switch event["event"] as? String {
        case "reset":
            reconciler.request()
        case "changed", "recovered":
            if let domain = registered(name) {
                signal(domain, resolving: [.serverUnreachable])
            }
        default:
            break
        }
    }

    /// Only the working set: the framework ignores any other container for a
    /// replicated extension.
    private func signal(_ domain: NSFileProviderDomain, resolving codes: [NSFileProviderError.Code]) {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.signalEnumerator(for: .workingSet) { _ in }
        for code in codes {
            manager.signalErrorResolved(NSFileProviderError(code)) { _ in }
        }
    }
}
