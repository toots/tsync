import FileProvider
import Foundation
import ServiceManagement

/// The domains of the config that are presented by the File Provider (§9.1
/// step 1); nil when the config cannot be read.
func configuredDomainNames(_ url: URL = Tsync.configFile) -> [String]? {
    guard
        let data = try? Data(contentsOf: url),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let domains = json["domains"] as? [[String: Any]] ?? []
    return domains.compactMap { domain in
        let frontends = domain["frontends"] as? [Any] ?? []
        let presented = frontends.contains { frontend in
            if let name = frontend as? String { return name == "file_provider" }
            return (frontend as? [String: Any])?["type"] as? String == "file_provider"
        }
        return presented ? domain["name"] as? String : nil
    }
}

/// What the menu shows of the last pass: names refused for a colliding
/// identifier, where removed domains left local edits, and failures.
struct ReconcileReport {
    var collisions: [String] = []
    var preserved: [String: URL] = [:]
    var failures: [String] = []
}

/// Domain registration (§9.1). Passes never overlap: one requested during a
/// pass runs once after it.
final class Reconciler {
    /// §13 registration_deadline / registration_retry.
    static let deadline: TimeInterval = 10
    static let retry: TimeInterval = 1

    private let queue = DispatchQueue(label: "org.feverdreamtv.tsync.reconcile")
    private let lock = NSLock()
    private var running = false
    private var again = false
    private var preserved: [String: URL] = [:]

    /// Called after each pass with the registered domains and the report.
    var onPass: (([NSFileProviderDomain], ReconcileReport) -> Void)?

    func request() {
        lock.lock()
        if running {
            again = true
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        queue.async { self.loop() }
    }

    private func loop() {
        while true {
            let (domains, report) = pass()
            onPass?(domains, report)
            lock.lock()
            if again {
                again = false
                lock.unlock()
                continue
            }
            running = false
            lock.unlock()
            return
        }
    }

    private func pass() -> ([NSFileProviderDomain], ReconcileReport) {
        var report = ReconcileReport()
        let until = Date().addingTimeInterval(Self.deadline)
        let fm = FileManager.default

        // Step 3: purge. Nothing is registered, and the marker goes only once
        // every domain was removed and the login item unregistered; the
        // service's agent is the purge command's to remove (§9.4).
        if fm.fileExists(atPath: Tsync.purgeMarker.path) {
            let (existing, _) = listDomains(until)
            let removed = existing.filter { remove($0, until, &report) }
            if removed.count == existing.count {
                try? SMAppService.mainApp.unregister()
                try? fm.removeItem(at: Tsync.purgeMarker)
            }
            return ([], report)
        }

        // Step 4: reconciling against no names would remove every domain.
        guard let names = configuredDomainNames() else {
            report.failures.append("the config cannot be read; domains left as they are")
            let (existing, _) = listDomains(until)
            return (existing, report)
        }

        let (existing, listed) = listDomains(until)
        let schemeRecorded =
            (try? String(contentsOf: Tsync.identitySchemeRecord, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == String(Tsync.identityScheme)
        let stale = schemeRecorded ? [] : existing.map(\.identifier.rawValue)
        let resetLines =
            ((try? String(contentsOf: Tsync.resetMarker, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let requested = Set(resetLines.map(domainIdentifier))

        // §3.3: two names with one identifier register neither.
        var byIdentifier: [String: [String]] = [:]
        for name in names { byIdentifier[domainIdentifier(name), default: []].append(name) }
        let colliding = byIdentifier.filter { $0.value.count > 1 }
        report.collisions = colliding.values.flatMap { $0 }.sorted()
        let wanted = byIdentifier.filter { $0.value.count == 1 }.mapValues { $0[0] }

        // Step 8.
        var survivors: [NSFileProviderDomain] = []
        var staleRemoved = true
        var requestedRemoved = true
        for domain in existing {
            let id = domain.identifier.rawValue
            let drop = wanted[id] == nil || requested.contains(id) || stale.contains(id)
            if !drop {
                survivors.append(domain)
                continue
            }
            if !remove(domain, until, &report) {
                survivors.append(domain)
                if stale.contains(id) { staleRemoved = false }
                if requested.contains(id) { requestedRemoved = false }
            }
        }

        // Step 9: added domains are signalled so their enumeration starts
        // without waiting for a user.
        var registered = survivors
        let present = Set(survivors.map(\.identifier.rawValue))
        for (id, name) in wanted.sorted(by: { $0.key < $1.key }) where !present.contains(id) {
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(id), displayName: name)
            domain.supportsSyncingTrash = false
            if let error = call(until, { NSFileProviderManager.add(domain, completionHandler: $0) }) {
                report.failures.append("\(name): \(error.localizedDescription)")
                continue
            }
            registered.append(domain)
            NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
        }

        // Steps 10, 11: only what this pass completed is recorded.
        if listed && staleRemoved && !schemeRecorded {
            try? String(Tsync.identityScheme).write(
                to: Tsync.identitySchemeRecord, atomically: true, encoding: .utf8)
        }
        if listed && requestedRemoved && !resetLines.isEmpty {
            try? fm.removeItem(at: Tsync.resetMarker)
        }

        // Preserved data is shown until a pass finds it gone.
        preserved = preserved.filter { fm.fileExists(atPath: $0.value.path) }
        report.preserved = preserved
        return (registered, report)
    }

    /// A failure to list counts as an empty list and marks the pass unlisted.
    private func listDomains(_ until: Date) -> ([NSFileProviderDomain], Bool) {
        var domains: [NSFileProviderDomain] = []
        let error = call(until) { done in
            NSFileProviderManager.getDomainsWithCompletionHandler { list, error in
                domains = list
                done(error)
            }
        }
        return (domains, error == nil)
    }

    /// Removal keeps local edits the system had not handed over yet.
    private func remove(
        _ domain: NSFileProviderDomain, _ until: Date, _ report: inout ReconcileReport
    ) -> Bool {
        var location: URL?
        let error = call(until) { done in
            NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData) { url, error in
                location = url
                done(error)
            }
        }
        if let error = error {
            report.failures.append("\(domain.displayName): \(error.localizedDescription)")
            return false
        }
        if let location = location {
            NSLog("tsync: %@ left local edits at %@", domain.displayName, location.path)
            preserved[domain.displayName] = location
        }
        return true
    }

    /// One framework call, retried while the installer swaps the extension
    /// (provider-not-found), all within the pass's deadline.
    private func call(_ until: Date, _ body: (@escaping (Error?) -> Void) -> Void) -> Error? {
        while true {
            let finished = DispatchSemaphore(value: 0)
            var failure: Error?
            body { error in
                failure = error
                finished.signal()
            }
            if finished.wait(timeout: .now() + max(0, until.timeIntervalSinceNow)) == .timedOut {
                return NSError(
                    domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "the system did not answer in time"])
            }
            guard let error = failure as NSError? else { return nil }
            let notFound =
                error.domain == NSFileProviderErrorDomain
                && error.code == NSFileProviderError.providerNotFound.rawValue
            if !notFound || Date().addingTimeInterval(Self.retry) > until { return error }
            Thread.sleep(forTimeInterval: Self.retry)
        }
    }
}
