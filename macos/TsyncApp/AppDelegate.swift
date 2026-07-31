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
        if await purgeIfRequested() { return }

        let domainNames: [String]
        if let config = try? Config.load() {
            domainNames = config.domains.map(\.name)
        } else {
            log.error("config not found or invalid, no domains will be registered")
            domainNames = []
        }

        let existing: [NSFileProviderDomain]
        do {
            existing = try await NSFileProviderManager.domains()
        } catch {
            log.error("domains() failed: \(error, privacy: .public)")
            existing = []
        }

        let configured = Set(domainNames.map(domainIdentifier))
        let reset = consumeResetMarker().union(await staleIdentityScheme(existing))

        for domain in existing
        where !configured.contains(domain.identifier.rawValue)
            || reset.contains(domain.identifier.rawValue) {
            do {
                try await NSFileProviderManager.remove(domain, mode: .removeAll)
                log.info("removed domain '\(domain.identifier.rawValue, privacy: .public)'")
            } catch {
                log.error("remove '\(domain.identifier.rawValue, privacy: .public)' failed: \(error, privacy: .public)")
            }
        }

        let surviving = Set(existing.map(\.identifier.rawValue)).subtracting(reset)

        for name in domainNames {
            let identifier = domainIdentifier(name)
            guard !surviving.contains(identifier) else { continue }
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: identifier),
                displayName: name)
            // There is no trash container to sync into, and this defaults to
            // true. Left on, Finder offers "Move to Trash" for an operation
            // nothing implements.
            domain.supportsSyncingTrash = false
            do {
                try await NSFileProviderManager.add(domain)
                log.info("registered domain '\(identifier, privacy: .public)'")
            } catch {
                log.error("add '\(identifier, privacy: .public)' failed: \(error, privacy: .public)")
            }
        }

        recordIdentityScheme()
        await startRelays()
    }

    /// One relay per domain, for as long as the app runs.
    private func startRelays() async {
        for domain in (try? await NSFileProviderManager.domains()) ?? [] {
            let relay = SignalRelay(domain: domain)
            relay.start()
            relays.append(relay)
        }
        log.info("relaying events for \(self.relays.count) domain(s)")
    }

    // MARK: - Identity scheme

    /// Items used to be identified by their storage path and now carry an opaque
    /// reference. Every identifier the system has recorded for an existing domain
    /// is in the old spelling and cannot be translated, so such a domain is
    /// rebuilt from scratch once. Downloaded content becomes dataless and comes
    /// back on next access; nothing in the store is touched.
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

    /// Written by `tsync fileprovider purge`: unregister every domain and
    /// register none. Deleting the marker last is how the CLI knows the domains
    /// are gone and it is safe to tear the rest down.
    private func purgeIfRequested() async -> Bool {
        let marker = Config.dataDirURL.appendingPathComponent("fileprovider-purge")
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }

        for domain in (try? await NSFileProviderManager.domains()) ?? [] {
            do {
                try await NSFileProviderManager.remove(domain, mode: .removeAll)
                log.info("purged domain '\(domain.identifier.rawValue, privacy: .public)'")
            } catch {
                log.error("purge '\(domain.identifier.rawValue, privacy: .public)' failed: \(error, privacy: .public)")
            }
        }
        await LoginItem.unregister()
        try? FileManager.default.removeItem(at: marker)
        return true
    }

    /// Domain names written by `tsync fileprovider reset`, one per line. They are
    /// removed before reconciling, so the loop above registers them afresh.
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
