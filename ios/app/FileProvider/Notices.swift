import FileProvider
import Foundation

/// The core's notices (android.md §4.2) become working-set signals: the
/// system asks the working set for changes only when signalled (ios.md §5.1).
enum Notices {
    private static let lock = NSLock()
    private static var started = false
    private static var booted = Set<String>()

    /// One thread for the process, blocked on the bridge between notices.
    static func start() {
        lock.lock()
        defer { lock.unlock() }
        if started { return }
        started = true
        Thread.detachNewThread {
            while true {
                guard let text = Core.text("next_notice", Data()) else {
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }
                guard
                    let notice = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                        as? [String: Any],
                    let event = notice["event"] as? String, let domain = notice["domain"] as? String,
                    event == "changed" || event == "recovered"
                else { continue }
                Footprint.append("\(domain) notice \(event)")
                signal(domain)
            }
        }
    }

    /// Whether this is the domain's first boot in this process.
    static func firstBoot(_ domain: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return booted.insert(domain).inserted
    }

    /// The system coalesces signals, so each notice signals.
    static func signal(_ domain: String) {
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
            guard let found = domains.first(where: { $0.displayName == domain }) else {
                Footprint.append("\(domain) signal: no such domain")
                return
            }
            NSFileProviderManager(for: found)?.signalEnumerator(for: .workingSet) { error in
                if let error { Footprint.append("\(domain) signal failed: \(error)") }
            }
        }
    }
}
