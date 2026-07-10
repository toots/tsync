import AppKit
import FileProvider
import OSLog

private let log = Logger(subsystem: "com.toots.tsync", category: "AppDelegate")

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

        let configuredIdentifiers = Set(domainNames.map {
            $0.lowercased().replacingOccurrences(of: " ", with: "-")
        })

        for domain in existingDomains where !configuredIdentifiers.contains(domain.identifier.rawValue) {
            do {
                try await NSFileProviderManager.remove(domain, mode: .removeAll)
                log.info("removed stale domain '\(domain.identifier.rawValue, privacy: .public)'")
            } catch {
                log.error("remove domain '\(domain.identifier.rawValue, privacy: .public)' failed: \(error, privacy: .public)")
            }
        }

        let existingIdentifiers = Set(existingDomains.map(\.identifier.rawValue))

        for name in domainNames {
            let identifier = name.lowercased().replacingOccurrences(of: " ", with: "-")
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
    }
}
