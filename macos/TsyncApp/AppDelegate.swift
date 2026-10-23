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
    /// The domains of the last pass, read on the main queue.
    private var served: [String] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.installEditMenu()
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
            let names = domains.map { $0.displayName }
            DispatchQueue.main.async { self.served = names }
        }
        reconciler.request()
        relay.start()
        watchScreenLock()
    }

    /// vault §6.2, security-model §10.6: a screen lock or sleep goes to every
    /// domain; the owner locks only one whose auto-lock policy asks for it.
    private func watchScreenLock() {
        let report: (Notification) -> Void = { [weak self] _ in
            let names = self?.served ?? []
            Thread.detachNewThread {
                for name in names {
                    _ = try? OwnerClient.call(
                        ["action": "vault_lock", "domain": name, "reason": "screen"])
                }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main,
            using: report)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: report)
    }

    /// An accessory app shows no menu bar, but ⌘V and its siblings still reach
    /// a text field only through an Edit menu's key equivalents: without one,
    /// nothing can be pasted into the app's dialogs.
    private static func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem())
        main.addItem(editItem)
        NSApp.mainMenu = main
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
