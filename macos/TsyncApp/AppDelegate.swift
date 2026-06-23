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
    private var pollerTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await registerDomains() }
        ipcServer.start()
        pollerTask = Task { await runVersionPoller() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollerTask?.cancel()
        ipcServer.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func runVersionPoller() async {
        guard let config = try? Config.load(),
              let credentials = try? KeychainCredentials.load() else {
            log.warning("poller: config/credentials unavailable, skipping")
            return
        }
        let client = S3Client(bucket: config.bucket, region: config.awsRegion, credentials: credentials)
        let stores = config.domains.map { S3Store(client: client, config: config, domainName: $0.name) }
        var knownVersions = [String?](repeating: nil, count: stores.count)

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            var changed = false
            for (i, store) in stores.enumerated() {
                let version = try? await store.fetchVersion()
                if knownVersions[i] != nil && version != knownVersions[i] {
                    changed = true
                    log.info("poller: version changed for \(store.domainName, privacy: .public)")
                }
                knownVersions[i] = version
            }
            if changed { await signalAllDomains() }
        }
        try? client.shutdown()
    }

    private func signalAllDomains() async {
        guard let domains = try? await NSFileProviderManager.domains() else { return }
        for domain in domains {
            guard let manager = NSFileProviderManager(for: domain) else { continue }
            manager.signalEnumerator(for: .workingSet) { error in
                if let error { log.error("poller: signal failed: \(error, privacy: .public)") }
            }
        }
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
