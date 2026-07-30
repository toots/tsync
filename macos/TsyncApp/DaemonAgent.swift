import Foundation
import OSLog
import ServiceManagement

private let log = Logger(subsystem: "org.feverdreamtv.tsync", category: "DaemonAgent")

/// The OCaml daemon ships inside the app bundle and runs as a bundled
/// LaunchAgent, so installing is a drag to /Applications and uninstalling is a
/// drag to the Trash.
enum DaemonAgent {
    private static let plistName = "org.feverdreamtv.tsync.daemon.plist"

    private static var isBundled: Bool {
        let plist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)")
        return FileManager.default.fileExists(atPath: plist.path)
    }

    static func register() {
        do {
            try SMAppService.mainApp.register()
        } catch {
            log.error("login item registration failed: \(error, privacy: .public)")
        }

        guard isBundled else {
            log.info("no bundled daemon, skipping agent registration")
            return
        }

        let agent = SMAppService.agent(plistName: plistName)
        guard agent.status != .enabled else { return }
        do {
            try agent.register()
            log.info("registered daemon agent")
        } catch {
            log.error("daemon agent registration failed: \(error, privacy: .public)")
        }
    }

    /// Deleting the app bundle would otherwise leave both services behind in the
    /// login-items database. Called when the CLI asks for a purge.
    static func unregister() async {
        for service in [SMAppService.agent(plistName: plistName), SMAppService.mainApp] {
            do {
                try await service.unregister()
            } catch {
                log.error("unregister failed: \(error, privacy: .public)")
            }
        }
    }
}
