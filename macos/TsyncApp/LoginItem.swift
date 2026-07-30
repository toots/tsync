import Foundation
import OSLog
import ServiceManagement

private let log = Logger(subsystem: "org.feverdreamtv.tsync", category: "LoginItem")

/// Registers the app to launch at login. The OCaml daemon is *not* handled here:
/// `SMAppService.agent` reports `.notFound` for a correctly placed, sealed and
/// Team-ID-signed agent in `Contents/Library/LaunchAgents`, so it never starts.
/// The daemon runs from a plain LaunchAgent instead — see `install-agent.sh`,
/// which the installer and `deploy.sh` both call.
enum LoginItem {
    static func register() {
        do {
            try SMAppService.mainApp.register()
        } catch {
            log.error("login item registration failed: \(error, privacy: .public)")
        }
    }

    /// Deleting the app bundle would otherwise leave the registration behind in
    /// the login-items database. Called when the CLI asks for a purge.
    static func unregister() async {
        do {
            try await SMAppService.mainApp.unregister()
        } catch {
            log.error("unregister failed: \(error, privacy: .public)")
        }
    }
}
