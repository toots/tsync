import FileProvider
import Foundation
import OSLog

private let log = Logger(subsystem: "org.feverdreamtv.tsync", category: "SignalRelay")

/// Carries the daemon's events to the system.
///
/// Only a process holding an `NSFileProviderManager` can signal the system, and
/// the daemon is not one. The extension cannot do it either: the OS stops it as
/// domains go idle, which is exactly when changes need reporting. The app is a
/// login item and stays up, so it subscribes — connecting outwards, since the
/// daemon cannot reach into a sandboxed process.
final class SignalRelay: @unchecked Sendable {
    private let domain: NSFileProviderDomain
    private let client: DaemonClient
    private var stopped = false

    init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.client = DaemonClient(domain: domain.displayName)
    }

    func start() {
        Thread.detachNewThread { [self] in
            // Back off but never give up, so the relay survives a `make install`
            // without anyone reconnecting it.
            var backoff = 1.0
            while !stopped {
                do {
                    // Events are not replayed, so whatever happened while no
                    // subscription was up is caught by asking once it is.
                    try client.subscribe(onSubscribed: { [self] in
                        backoff = 1.0
                        signalWorkingSet(because: "subscribed")
                    }, onEvent: { [self] event in handle(event) })
                } catch {
                    log.debug("subscribe: \(error, privacy: .public)")
                }
                if stopped { break }
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 2, 30)
            }
        }
    }

    func stop() { stopped = true }

    /// A replicated extension may signal only the working set; the system
    /// propagates from there. Signalling a specific item is ignored.
    private func signalWorkingSet(because reason: String) {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        log.debug("signalling working set for \(reason, privacy: .public)")
        manager.signalEnumerator(for: .workingSet) { error in
            if let error { log.error("signalEnumerator: \(error, privacy: .public)") }
        }
        // `serverUnreachable` latches the domain off until cleared, so clear
        // it on any news or a transient outage sticks.
        manager.signalErrorResolved(NSFileProviderError(.serverUnreachable)) { _ in }
    }

    private func handle(_ event: DaemonEvent) {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        switch event.event {
        case "changed", "resync":
            signalWorkingSet(because: event.event)

        case "evict":
            guard let ref = event.ref else { return }
            manager.evictItem(identifier: NSFileProviderItemIdentifier(ref)) { error in
                if let error { log.error("evictItem: \(error, privacy: .public)") }
            }

        case "restore":
            guard let ref = event.ref else { return }
            // Reading through a coordinator would also pull the file down, but
            // only as a side effect of pretending to want the bytes.
            manager.requestDownloadForItem(
                withIdentifier: NSFileProviderItemIdentifier(ref),
                requestedRange: NSRange(location: NSNotFound, length: 0)
            ) { error in
                if let error { log.error("requestDownload: \(error, privacy: .public)") }
            }

        default:
            log.debug("ignoring event \(event.event, privacy: .public)")
        }
    }
}
