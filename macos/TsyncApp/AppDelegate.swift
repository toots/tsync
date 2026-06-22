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

    private let ipcServer = IPCServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await registerDomains() }
        ipcServer.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipcServer.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func registerDomains() async {
        let configURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.toots.tsync")?
            .appendingPathComponent("config.json") ?? URL(fileURLWithPath: "")

        let domainNames: [String]
        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            domainNames = config.domains.map(\.name)
        } else {
            log.warning("config not found, using default domain")
            domainNames = ["Music Production"]
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
                try await NSFileProviderManager.remove(domain)
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
