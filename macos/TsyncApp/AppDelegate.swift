import AppKit
import FileProvider
import OSLog

private let log = Logger(subsystem: "org.feverdreamtv.tsync", category: "AppDelegate")

private func domainIdentifier(_ name: String) -> String {
    name.lowercased().replacingOccurrences(of: " ", with: "-")
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var relays: [SignalRelay] = []
    private var statusMenu: StatusMenu?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.register()
        Task { await registerDomains() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func registerDomains() async {
        let config = try? Config.load()
        let domainNames = config?.domains.map(\.name) ?? []

        // Ahead of anything that can fail or return early, so a failure shows
        // up in the menu bar instead of leaving no interface at all.
        statusMenu = await StatusMenu(domains: domainNames)

        // One window for the whole launch, not one per call: multiplied by the
        // number of domains, a per-call budget outruns the CLI waiting on a
        // purge and has it call the purge failed while it is still going.
        let deadline = Date().addingTimeInterval(Self.invalidationWindow)

        if await purgeIfRequested(until: deadline) { return }

        // Reconciling against no names would remove every domain and the local
        // copies with it, and a config that cannot be read names nothing.
        guard config != nil else {
            log.error("config not found or invalid, domains left as they are")
            await startRelays()
            return
        }

        let existing: [NSFileProviderDomain]
        var listed = true
        do {
            existing = try await retryingWhileInvalidating(until: deadline) {
                try await NSFileProviderManager.domains()
            }
        } catch {
            log.error("domains() failed: \(error, privacy: .public)")
            existing = []
            listed = false
        }

        let configured = Set(domainNames.map(domainIdentifier))
        let stale = await staleIdentityScheme(existing)
        let reset = consumeResetMarker().union(stale)

        let unwanted = existing.filter {
            !configured.contains($0.identifier.rawValue)
                || reset.contains($0.identifier.rawValue)
        }
        let removed = await remove(unwanted, until: deadline)

        let surviving = Set(existing.map(\.identifier.rawValue)).subtracting(removed)

        for name in domainNames {
            let identifier = domainIdentifier(name)
            guard !surviving.contains(identifier) else { continue }
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: identifier),
                displayName: name)
            // Defaults to true, which makes Finder offer "Move to Trash" for an
            // operation nothing implements.
            domain.supportsSyncingTrash = false
            do {
                try await retryingWhileInvalidating(until: deadline) {
                    try await NSFileProviderManager.add(domain)
                }
                log.info("registered domain '\(identifier, privacy: .public)'")
            } catch {
                log.error("add '\(identifier, privacy: .public)' failed: \(error, privacy: .public)")
            }
        }

        // A domain still spelling the old identifiers is rebuilt at the next
        // launch, which recording the scheme now would call off. Only those
        // count: a domain merely dropped from the config that the system will
        // not let go of would otherwise pin every launch to a rebuild of all
        // the others, whose content goes dataless and comes back down each time.
        if listed, stale.isSubset(of: removed) { recordIdentityScheme() }
        await startRelays()
    }

    /// The identifiers of the domains that did go.
    private func remove(_ domains: [NSFileProviderDomain],
                        until deadline: Date) async -> Set<String> {
        var removed: Set<String> = []
        for domain in domains {
            let identifier = domain.identifier.rawValue
            do {
                try await retryingWhileInvalidating(until: deadline) {
                    try await NSFileProviderManager.remove(domain, mode: .removeAll)
                }
                log.info("removed domain '\(identifier, privacy: .public)'")
                removed.insert(identifier)
            } catch {
                log.error("remove '\(identifier, privacy: .public)' failed: \(error, privacy: .public)")
            }
        }
        return removed
    }

    /// How long one launch may spend waiting on a provider that is still
    /// invalidating, across every call it makes.
    private static let invalidationWindow: TimeInterval = 10

    /// The system rejects domain calls with `providerNotFound` ("is in the
    /// process of being invalidated. Retry later.") while it swaps the
    /// extension registration — which is what the installer opening the app
    /// races against on every fresh install.
    ///
    /// The deadline is shared by every call of one launch, so the wait stays
    /// what it says however many domains there are to reconcile.
    private func retryingWhileInvalidating<T>(until deadline: Date,
                                              _ body: () async throws -> T) async throws -> T {
        while true {
            do {
                return try await body()
            } catch let error as NSError where error.domain == NSFileProviderErrorDomain
                && error.code == NSFileProviderError.Code.providerNotFound.rawValue {
                guard Date() < deadline else { throw error }
                log.info("provider still invalidating, retrying")
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// One relay per domain, for as long as the app runs.
    private func startRelays() async {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        for domain in domains {
            let relay = SignalRelay(domain: domain)
            relay.start()
            relays.append(relay)
        }
        log.info("relaying events for \(self.relays.count) domain(s)")
    }

    // MARK: - Identity scheme

    /// Identifiers recorded by the system before items carried opaque references
    /// spell paths and cannot be translated, so such a domain is rebuilt from
    /// scratch once. Content goes dataless and returns on next access; the store
    /// is untouched.
    private static let identityScheme = 1

    private static var identityMarker: URL {
        Config.dataDirURL.appendingPathComponent("fileprovider-identity-scheme")
    }

    private func staleIdentityScheme(_ existing: [NSFileProviderDomain]) async -> Set<String> {
        let recorded = (try? String(contentsOf: Self.identityMarker, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        guard recorded < Self.identityScheme else { return [] }
        let names = existing.map(\.identifier.rawValue)
        if !names.isEmpty {
            log.info("identifier scheme changed, rebuilding \(names.count) domain(s)")
        }
        return Set(names)
    }

    private func recordIdentityScheme() {
        try? FileManager.default.createDirectory(at: Config.dataDirURL,
                                                 withIntermediateDirectories: true)
        try? "\(Self.identityScheme)".write(to: Self.identityMarker,
                                            atomically: true, encoding: .utf8)
    }

    // MARK: - Markers

    /// Written by `tsync fileprovider purge`: unregister every domain, register
    /// none. The marker is deleted last and only once every domain is gone,
    /// which is how the CLI knows the rest can be torn down.
    private func purgeIfRequested(until deadline: Date) async -> Bool {
        let marker = Config.dataDirURL.appendingPathComponent("fileprovider-purge")
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }

        do {
            let domains = try await retryingWhileInvalidating(until: deadline) {
                try await NSFileProviderManager.domains()
            }
            guard await remove(domains, until: deadline).count == domains.count
            else { return true }
        } catch {
            log.error("purge: domains() failed: \(error, privacy: .public)")
            return true
        }
        await LoginItem.unregister()
        try? FileManager.default.removeItem(at: marker)
        return true
    }

    /// Domain names written by `tsync fileprovider reset`, one per line. Removed
    /// before reconciling, so the loop above registers them afresh.
    private func consumeResetMarker() -> Set<String> {
        let marker = Config.dataDirURL.appendingPathComponent("fileprovider-reset")
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return [] }
        try? FileManager.default.removeItem(at: marker)
        return Set(
            text.split(separator: "\n")
                .map { domainIdentifier($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty })
    }
}
