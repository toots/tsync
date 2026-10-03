import AppKit
import FileProvider
import ServiceManagement

/// The login item (§2): registers the service and itself, reconciles domains,
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
        menu.update(registrationProblem: registerServices())
        reconciler.onPass = { [relay] domains, report in
            relay.update(domains)
            menu.update(domains: domains, report: report)
        }
        reconciler.request()
        relay.start()
    }

    /// §11: the login item and the service's agent, both through the
    /// service-management API. Answers what the menu should say when either
    /// failed.
    private func registerServices() -> String? {
        if FileManager.default.fileExists(atPath: Tsync.purgeMarker.path) { return nil }
        var problems: [String] = []
        do { try SMAppService.mainApp.register() } catch {
            problems.append("login item: \(error.localizedDescription)")
        }
        let agent = SMAppService.agent(plistName: Reconciler.agentPlist)
        if agent.status != .enabled {
            do { try agent.register() } catch {
                problems.append("service: \(error.localizedDescription)")
            }
        }
        return problems.isEmpty ? nil : "Not registered: " + problems.joined(separator: "; ")
    }
}
