import FileProvider
import Foundation
import OSLog

private let log = Logger(subsystem: "org.feverdreamtv.tsync", category: "SignalRelay")

/// Carries the daemon's events to the system.
///
/// Only a process holding an `NSFileProviderManager` can tell the system
/// anything, and the daemon is not one — so somebody has to bridge the two. The
/// extension is the wrong somebody: the OS starts and stops it as domains go
/// idle, so a channel that only exists while it runs is missing exactly when
/// changes need reporting. The app is a login item and stays up, so it is the
/// one that subscribes.
///
/// The connection is made outwards, from here to the daemon. The previous design
/// had the daemon connect into a socket the extension listened on; on a real
/// machine that socket was never created, so every eviction, restore and change
/// notice went nowhere for as long as the feature existed.
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
            // The daemon restarts, and an install stops it for a moment. Backing
            // off rather than spinning, and never giving up, is what makes the
            // relay survive a `make install` without anyone reconnecting it.
            var backoff = 1.0
            while !stopped {
                do {
                    try client.subscribe { [self] event in
                        backoff = 1.0
                        handle(event)
                    }
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

    private func handle(_ event: DaemonEvent) {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        switch event.event {
        case "changed", "resync":
            // For a replicated extension only the working set may be signalled;
            // the system propagates from there to whatever is on screen. Signalling
            // a specific item is documented as ignored.
            manager.signalEnumerator(for: .workingSet) { error in
                if let error { log.error("signalEnumerator: \(error, privacy: .public)") }
            }
            // A store that was unreachable leaves the domain backed off until it
            // is told the problem is over. Saying so on any news is cheap, and
            // not saying it leaves a domain stuck after a transient outage.
            manager.signalErrorResolved(NSFileProviderError(.serverUnreachable)) { _ in }

        case "evict":
            guard let ref = event.ref else { return }
            manager.evictItem(identifier: NSFileProviderItemIdentifier(ref)) { error in
                if let error { log.error("evictItem: \(error, privacy: .public)") }
            }

        case "restore":
            guard let ref = event.ref else { return }
            // Asking the system to schedule a download is what a restore means.
            // Reading the file through a coordinator would also pull it down, but
            // as a side effect of pretending to want the bytes.
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
