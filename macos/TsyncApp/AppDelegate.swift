import AppKit
import FileProvider
import ServiceManagement

/// The login item (§2): registers itself, reconciles domains,
/// relays the owner's events and shows the menu. It never offers to quit:
/// without it no remote change reaches the replica until the next login.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let reconciler = Reconciler()
    private lazy var relay = Relay(reconciler: reconciler)
    private var menu: StatusMenu?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The menu comes first, so a failure below still shows something.
        let menu = StatusMenu(pause: { paused in
            Thread.detachNewThread {
                _ = try? OwnerClient.call(["action": "pause", "arg": paused ? "on" : "off"])
            }
        })
        self.menu = menu
        menu.update(registrationProblem: registerLoginItem())
        reconciler.onPass = { [relay] domains, report in
            relay.update(domains)
            menu.update(domains: domains, report: report)
        }
        reconciler.request()
        relay.start()
    }

    /// §11: the app as a login item. The service's agent is the installer's:
    /// a sandboxed app may register only sandboxed agents. Answers what the menu
    /// should say when registration failed.
    private func registerLoginItem() -> String? {
        if FileManager.default.fileExists(atPath: Tsync.purgeMarker.path) { return nil }
        do { try SMAppService.mainApp.register() } catch {
            return "Not registered as a login item: \(error.localizedDescription)"
        }
        return nil
    }
}
