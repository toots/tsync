import AppKit
import SwiftUI
import AuthenticationServices
import FileProvider
import UserNotifications

/// §10: the status item. Its image and tooltip are the owner's (`menu`); a
/// click opens the panel, the Activity screen. No quit.
final class StatusMenu: NSObject, NSPopoverDelegate {
    /// §13 menu_poll_interval.
    static let pollInterval: TimeInterval = 3

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = PanelModel()
    private let lock = NSLock()
    private var polling = false
    /// The codes menu's last fetch: an older one's reply is dropped.
    private var codesFetch = 0
    private var report = ReconcileReport()
    private var registrationProblem: String?
    private var domains: [String: NSFileProviderDomain] = [:]

    let pause: (Bool) -> Void

    init(pause: @escaping (Bool) -> Void) {
        self.pause = pause
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        item.button?.target = self
        item.button?.action = #selector(toggle)
        model.pause = { [weak self] paused in
            self?.pause(paused)
            self?.poll()
        }
        model.showCodes = { [weak self] in self?.showCodes() }
        model.openSettings = { [weak self] in self?.openAutofillSettings() }
        model.open = { [weak self] name in self?.withRoot(of: name) { NSWorkspace.shared.open($0) } }
        model.reveal = { [weak self] name, rel in
            self?.withRoot(of: name) {
                NSWorkspace.shared.activateFileViewerSelecting([$0.appendingPathComponent(rel)])
            }
        }
        draw(nil)
        Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
        if #available(macOS 14.0, *) {
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Identities.refresh() }
            Identities.refresh()
        }
    }

    func update(domains registered: [NSFileProviderDomain], report: ReconcileReport) {
        DispatchQueue.main.async {
            self.domains = Dictionary(uniqueKeysWithValues: registered.map { ($0.displayName, $0) })
            self.report = report
            self.model.domains = Tsync.domainNames().filter { self.domains[$0] != nil }
            self.model.notices = self.localLines()
        }
    }

    func update(registrationProblem: String?) {
        DispatchQueue.main.async {
            self.registrationProblem = registrationProblem
            self.model.notices = self.localLines()
        }
    }

    /// A fresh view each time it opens, dropped when it closes: the panel
    /// polls only while it is shown.
    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        checkAutofill()
        if #available(macOS 14.0, *) { Identities.refresh() }
        popover.contentViewController = NSHostingController(rootView: Panel(model: model))
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    /// One poll at a time; a poll past its deadline counts as a failure and
    /// releases the latch.
    private func poll() {
        lock.lock()
        if polling {
            lock.unlock()
            return
        }
        polling = true
        lock.unlock()
        Thread.detachNewThread {
            let reply = try? OwnerClient.call(["action": "menu"], deadline: Self.pollInterval * 2)
            self.lock.lock()
            self.polling = false
            self.lock.unlock()
            DispatchQueue.main.async { self.draw(reply?["menu"] as? [String: Any]) }
        }
    }

    /// An owner that cannot be reached shows the error icon and says so,
    /// rather than the last known state.
    private func draw(_ menu: [String: Any]?) {
        let icon = menu?["icon"] as? String ?? "tsync-error-symbolic"
        let image = NSImage(named: icon) ?? NSImage(named: "tsync-idle-symbolic")
        image?.isTemplate = true
        item.button?.image = image
        let tooltip = menu?["tooltip"] as? String ?? "tsync: the service is unreachable"
        item.button?.toolTip = tooltip
        let entries = menu?["entries"] as? [[String: Any]] ?? []
        let actions = entries.compactMap { $0["action"] as? [String: Any] }
        model.icon = icon
        model.reachable = menu != nil
        model.summary = menu == nil ? "The service is unreachable" : Self.summary(tooltip)
        model.allPaused = entries.contains { $0["checked"] as? Bool == true && ($0["action"] as? [String: Any])?["setPaused"] != nil }
        model.hasCodes = actions.contains { $0["codes"] as? Bool == true }
    }

    /// menu-model §4: the tooltip is `tsync — <summary>`.
    private static func summary(_ tooltip: String) -> String {
        guard let range = tooltip.range(of: " — ") else { return tooltip }
        return String(tooltip[range.upperBound...])
    }

    /// passwords/macos §1: asked when the panel opens, off the main queue.
    private func checkAutofill() {
        guard #available(macOS 14.0, *), Self.hasCredentialsExtension else { return }
        ASCredentialIdentityStore.shared.getState { state in
            let enabled = state.isEnabled
            DispatchQueue.global().async {
                let off = !enabled && self.anyDomainUsesPasswords()
                DispatchQueue.main.async { self.model.autofillOff = off }
            }
        }
    }

    /// A build without the extension's profile carries no extension (build.sh).
    private static let hasCredentialsExtension: Bool = {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(
            atPath: plugins.appendingPathComponent("TsyncCredentials.appex").path)
    }()

    /// A domain answering a passwords request, or refusing it as locked.
    private func anyDomainUsesPasswords() -> Bool {
        Tsync.domainNames().contains { name in
            do {
                _ = try OwnerClient.call(["action": "passwords_list", "domain": name, "use": false])
                return true
            } catch let failure as OwnerFailure {
                return failure.code == "locked"
            } catch { return false }
        }
    }

    /// macOS has no stable link to the AutoFill pane: the row names the path.
    private func openAutofillSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func localLines() -> [String] {
        var lines: [String] = []
        if let problem = registrationProblem { lines.append(problem) }
        if !report.collisions.isEmpty {
            lines.append("Not registered, same identifier: " + report.collisions.joined(separator: ", "))
        }
        for (name, url) in report.preserved.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): local edits kept at \(url.path)")
        }
        lines.append(contentsOf: report.failures)
        return lines
    }

    /// §10.1: the codes menu, under the pointer; fetched each time it opens.
    private func showCodes() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(Self.placeholder())
        fetchCodes(menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func menuItem(_ entry: [String: Any]) -> NSMenuItem {
        if entry["separator"] as? Bool == true { return .separator() }
        let title = entry["label"] as? String ?? ""
        let item = NSMenuItem(title: title, action: #selector(act(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = entry["enabled"] as? Bool ?? true
        item.indentationLevel = entry["indent"] as? Int ?? 0
        item.representedObject = entry["action"]
        return item
    }

    private static func placeholder() -> NSMenuItem {
        let placeholder = NSMenuItem(title: "Reading…", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        return placeholder
    }

    /// The owner's rows for the code domains: labels only, a record's code is
    /// asked for when it is clicked. A failure leaves the placeholder.
    private func fetchCodes(_ menu: NSMenu) {
        codesFetch += 1
        let fetch = codesFetch
        Thread.detachNewThread {
            let reply = try? OwnerClient.call(["action": "menu_codes"])
            guard let entries = reply?["entries"] as? [[String: Any]] else { return }
            // vault §8.1: a header row names its vault and carries its mark; code rows carry none.
            let domains = Set(entries.compactMap { $0["vault"] as? String })
            var looks: [String: NSImage] = [:]
            for domain in domains { looks[domain] = VaultLook.image(domain: domain) }
            DispatchQueue.main.async {
                guard fetch == self.codesFetch else { return }
                menu.removeAllItems()
                for entry in entries {
                    let item = self.menuItem(entry)
                    if let domain = entry["vault"] as? String { item.image = looks[domain] }
                    menu.addItem(item)
                }
            }
        }
    }

    @objc private func act(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? [String: Any] else { return }
        if let copy = action["copyCode"] as? [String: Any],
            let domain = copy["domain"] as? String, let id = copy["id"] as? String
        {
            copyCode(domain: domain, id: id)
        } else if let domain = action["unlock"] as? String {
            unlock(domain: domain, problem: nil)
        } else if let domain = action["addCode"] as? String {
            addCode(domain: domain, problem: nil)
        }
    }

    /// security-model §10.6: copied on the user's click, marked concealed so
    /// clipboard managers and history skip it, never logged or kept.
    private func copyCode(domain: String, id: String) {
        Thread.detachNewThread {
            do {
                let reply = try OwnerClient.call(
                    ["action": "totp_code", "domain": domain, "id": id])
                guard let code = reply["code"] as? String else { return }
                DispatchQueue.main.async {
                    let pasteboard = NSPasteboard.general
                    let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
                    pasteboard.clearContents()
                    pasteboard.declareTypes([.string, concealed], owner: nil)
                    pasteboard.setString(code, forType: .string)
                    pasteboard.setString("", forType: concealed)
                }
            } catch let failure as OwnerFailure {
                Self.notify(title: "Code not copied", body: failure.message)
            } catch {
                Self.notify(title: "Code not copied", body: "\(error)")
            }
        }
    }

    private static func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// §10.1: a secure field for the passphrase, and one for the secret key
    /// when this machine is not enrolled; cleared once sent. A refusal keeps
    /// the dialog open with the owner's sentence. Neither secret is kept.
    private func unlock(domain: String, problem: String?) {
        Thread.detachNewThread {
            do {
                let status = try OwnerClient.call(["action": "vault_status", "domain": domain])
                let enrolled = status["enrolled"] as? Bool ?? false
                DispatchQueue.main.async {
                    self.unlockDialog(domain: domain, enrolled: enrolled, problem: problem)
                }
            } catch {
                let reason = (error as? OwnerFailure)?.message ?? "\(error)"
                DispatchQueue.main.async { self.statusFailed(domain: domain, reason: reason) }
            }
        }
    }

    /// §10.1: a status that fails is shown, not guessed.
    private func statusFailed(domain: String, reason: String) {
        let alert = NSAlert()
        alert.messageText = "Cannot unlock the vault of \(domain)"
        alert.informativeText = reason
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func unlockDialog(domain: String, enrolled: Bool, problem: String?) {
        let alert = NSAlert()
        alert.messageText = "Unlock the vault of \(domain)"
        alert.informativeText =
            problem
            ?? (enrolled
                ? "Type or paste your passphrase."
                : "This Mac needs your passphrase and the vault's secret key.")
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        let passphrase = Self.secureField(placeholder: "Passphrase")
        let secretKey = Self.secureField(placeholder: "Secret key")
        alert.accessoryView = Self.column(enrolled ? [passphrase] : [passphrase, secretKey])
        alert.window.initialFirstResponder = passphrase.input
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var request: [String: Any] = [
            "action": "vault_unlock", "domain": domain, "passphrase": passphrase.stringValue,
        ]
        if !enrolled && !secretKey.stringValue.isEmpty { request["secretKey"] = secretKey.stringValue }
        passphrase.stringValue = ""
        secretKey.stringValue = ""
        Thread.detachNewThread {
            do {
                _ = try OwnerClient.call(request)
            } catch let failure as OwnerFailure {
                DispatchQueue.main.async {
                    self.unlockDialog(domain: domain, enrolled: enrolled, problem: failure.message)
                }
            } catch {
                DispatchQueue.main.async {
                    self.unlockDialog(domain: domain, enrolled: enrolled, problem: "\(error)")
                }
            }
        }
    }

    /// The domain's user-visible root, asked of the framework, never derived
    /// from the display name.
    private func withRoot(of name: String, _ body: @escaping (URL) -> Void) {
        guard let domain = domains[name], let manager = NSFileProviderManager(for: domain) else { return }
        manager.getUserVisibleURL(for: .rootContainer) { url, _ in
            guard let url = url else { return }
            DispatchQueue.main.async { body(url) }
        }
    }

    /// §10.1: issuer, account, and a secret that also takes a pasted
    /// otpauth URI. A refusal keeps the dialog open with the owner's sentence.
    private func addCode(domain: String, problem: String?, issuer typedIssuer: String = "",
                         account typedAccount: String = "") {
        let alert = NSAlert()
        alert.messageText = "Add a one-time code to \(domain)"
        alert.informativeText =
            problem ?? "Paste the text code the service shows, or its otpauth:// link."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let issuer = NSTextField(string: typedIssuer)
        issuer.placeholderString = "Service (GitHub)"
        let account = NSTextField(string: typedAccount)
        account.placeholderString = "Account (me@example.com)"
        let secret = Self.secureField(placeholder: "Secret, or otpauth:// link")
        alert.accessoryView = Self.column([issuer, account, secret])
        alert.window.initialFirstResponder = issuer
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let typed = secret.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        secret.stringValue = ""
        var request: [String: Any] = ["action": "totp_add", "domain": domain]
        if typed.lowercased().hasPrefix("otpauth://") {
            request["uri"] = typed
        } else {
            request["secret"] = typed
            request["issuer"] = issuer.stringValue
            request["account"] = account.stringValue
        }
        let kept = (issuer.stringValue, account.stringValue)
        Thread.detachNewThread {
            do {
                _ = try OwnerClient.call(request)
            } catch {
                let reason = (error as? OwnerFailure)?.message ?? "\(error)"
                DispatchQueue.main.async {
                    self.addCode(domain: domain, problem: reason, issuer: kept.0, account: kept.1)
                }
            }
        }
    }

    private static func secureField(placeholder: String) -> SecretField {
        SecretField(placeholder: placeholder)
    }

    /// An alert sizes its accessory view by its frame: views laid out by
    /// frame, one under the other, keep their width.
    private static func column(_ views: [NSView]) -> NSView {
        let width: CGFloat = 300
        let gap: CGFloat = 8
        let heights = views.map { $0 is SecretField ? SecretField.height : 24 }
        let total = heights.reduce(0, +) + CGFloat(views.count - 1) * gap
        let column = NSView(frame: NSRect(x: 0, y: 0, width: width, height: total))
        var top = total
        for (view, height) in zip(views, heights) {
            top -= height
            view.frame = NSRect(x: 0, y: top, width: width, height: height)
            column.addSubview(view)
            top -= gap
        }
        return column
    }
}
