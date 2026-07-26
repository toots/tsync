import AppKit
import FileProvider
import OSLog

private let log = Logger(subsystem: "com.toots.tsync", category: "AppDelegate")

private func domainIdentifier(_ name: String) -> String {
    name.lowercased().replacingOccurrences(of: " ", with: "-")
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        let existingDomains: [NSFileProviderDomain]
        do {
            existingDomains = try await NSFileProviderManager.domains()
        } catch {
            log.error("domains() failed: \(error, privacy: .public)")
            existingDomains = []
        }

        let configuredIdentifiers = Set(domainNames.map(domainIdentifier))
        let resetIdentifiers = consumeResetMarker()

        for domain in existingDomains
        where !configuredIdentifiers.contains(domain.identifier.rawValue)
            || resetIdentifiers.contains(domain.identifier.rawValue) {
            do {
                try await NSFileProviderManager.remove(domain, mode: .removeAll)
                log.info("removed domain '\(domain.identifier.rawValue, privacy: .public)'")
            } catch {
                log.error("remove domain '\(domain.identifier.rawValue, privacy: .public)' failed: \(error, privacy: .public)")
            }
        }

        let existingIdentifiers = Set(existingDomains.map(\.identifier.rawValue))
            .subtracting(resetIdentifiers)

        for name in domainNames {
            let identifier = domainIdentifier(name)
            guard !existingIdentifiers.contains(identifier) else { continue }
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: identifier),
                displayName: name
            )
            do {
                try await NSFileProviderManager.add(domain)
                log.info("registered domain '\(identifier, privacy: .public)'")
            } catch {
                log.error("add domain '\(identifier, privacy: .public)' failed: \(error, privacy: .public)")
            }
        }

        await reimportIfSchemaChanged()
    }

    /// Marker written by `tsync fileprovider purge`: unregister every domain and
    /// register none. Deleting the marker last is how the CLI knows the domains
    /// are gone and it is safe to tear the app down.
    private func purgeIfRequested() async -> Bool {
        let marker = Config.groupContainerURL
            .appendingPathComponent("tsync/fileprovider-purge")
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }

        for domain in (try? await NSFileProviderManager.domains()) ?? [] {
            do {
                try await NSFileProviderManager.remove(domain, mode: .removeAll)
                log.info("purged domain '\(domain.identifier.rawValue, privacy: .public)'")
            } catch {
                log.error("purge domain '\(domain.identifier.rawValue, privacy: .public)' failed: \(error, privacy: .public)")
            }
        }
        try? FileManager.default.removeItem(at: marker)
        return true
    }

    /// Domain names written by `tsync fileprovider reset`, one per line. They are
    /// removed before reconciling so the loop above re-registers them from scratch.
    private func consumeResetMarker() -> Set<String> {
        let marker = Config.groupContainerURL
            .appendingPathComponent("tsync/fileprovider-reset")
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return [] }
        try? FileManager.default.removeItem(at: marker)
        return Set(
            text.split(separator: "\n")
                .map { domainIdentifier($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
        )
    }

    /// The extension maps S3 keys to FileProvider items via a fixed key layout
    /// (currently `tsync/<domain>/manifests/…`). When that mapping changes, the OS
    /// keeps serving a stale index and never re-asks the extension, so an existing
    /// domain can be stuck showing wrong or empty contents. Bumping this version
    /// forces one `reimportItems` per domain to drop the stale index and re-list.
    private static let itemSchemaVersion = 3

    private func reimportIfSchemaChanged() async {
        let marker = Config.groupContainerURL
            .appendingPathComponent("tsync/fileprovider-schema-version")
        let stored = (try? String(contentsOf: marker, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        guard stored < Self.itemSchemaVersion else { return }

        let domains = (try? await NSFileProviderManager.domains()) ?? []
        for domain in domains {
            guard let manager = NSFileProviderManager(for: domain) else { continue }
            do {
                try await manager.reimportItems(below: .rootContainer)
                log.info("reimported domain '\(domain.identifier.rawValue, privacy: .public)'")
            } catch {
                log.error("reimport '\(domain.identifier.rawValue, privacy: .public)' failed: \(error, privacy: .public)")
            }
        }
        try? "\(Self.itemSchemaVersion)".write(to: marker, atomically: true, encoding: .utf8)
    }
}
