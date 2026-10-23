import AppKit
import FileProvider
import UserNotifications

/// §10: the status item. The owner renders its content (`menu`); the app only
/// draws it, and adds what only it knows (registration problems). No quit row.
final class StatusMenu: NSObject, NSMenuDelegate {
    /// §13 menu_poll_interval / menu_stats_interval.
    static let pollInterval: TimeInterval = 3
    static let statsInterval: TimeInterval = 1

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let lock = NSLock()
    private var polling = false
    private var isOpen = false
    private var latest: [String: Any]?
    private var reachable = true
    private var report = ReconcileReport()
    private var registrationProblem: String?
    private var domains: [String: NSFileProviderDomain] = [:]
    private var statsFetched = Date.distantPast
    private var statsEntries: [[String: Any]]?
    /// §10.1: fetched each time it opens, never cached.
    private var codesSubmenu: NSMenu?

    let pause: (Bool) -> Void

    init(pause: @escaping (Bool) -> Void) {
        self.pause = pause
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        rebuild()
        Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func update(domains registered: [NSFileProviderDomain], report: ReconcileReport) {
        DispatchQueue.main.async {
            self.domains = Dictionary(uniqueKeysWithValues: registered.map { ($0.displayName, $0) })
            self.report = report
            if !self.isOpen { self.rebuild() }
        }
    }

    func update(registrationProblem: String?) {
        DispatchQueue.main.async {
            self.registrationProblem = registrationProblem
            if !self.isOpen { self.rebuild() }
        }
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
            DispatchQueue.main.async {
                self.latest = reply?["menu"] as? [String: Any]
                self.reachable = self.latest != nil
                if !self.isOpen { self.rebuild() }
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === codesSubmenu {
            menu.removeAllItems()
            menu.addItem(Self.placeholder())
            fetchCodes(menu)
            return
        }
        isOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === codesSubmenu { return }
        isOpen = false
        rebuild()
    }

    /// An owner that cannot be reached shows the error icon and says so,
    /// rather than the last known state.
    private func rebuild() {
        let model = reachable ? latest : nil
        let icon = model?["icon"] as? String ?? "tsync-error-symbolic"
        let image = NSImage(named: icon) ?? NSImage(named: "tsync-idle-symbolic")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = model?["tooltip"] as? String ?? "tsync: the service is unreachable"

        menu.removeAllItems()
        for line in localLines() {
            let entry = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        }
        if !localLines().isEmpty { menu.addItem(.separator()) }
        if let model = model {
            for entry in model["entries"] as? [[String: Any]] ?? [] {
                menu.addItem(menuItem(entry))
            }
        } else {
            let entry = NSMenuItem(title: "The tsync service is unreachable", action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        }
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

    private func menuItem(_ entry: [String: Any]) -> NSMenuItem {
        if entry["separator"] as? Bool == true { return .separator() }
        let title = entry["label"] as? String ?? ""
        let item = NSMenuItem(title: title, action: #selector(act(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = entry["enabled"] as? Bool ?? true
        item.indentationLevel = entry["indent"] as? Int ?? 0
        if let checked = entry["checked"] as? Bool { item.state = checked ? .on : .off }
        item.representedObject = entry["action"]
        if entry["submenu"] as? Bool == true {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            if (entry["action"] as? [String: Any])?["codes"] as? Bool == true {
                submenu.delegate = self
                submenu.addItem(Self.placeholder())
                codesSubmenu = submenu
            } else {
                fillStats(submenu)
            }
            item.submenu = submenu
            item.action = nil
        }
        return item
    }

    private static func placeholder() -> NSMenuItem {
        let placeholder = NSMenuItem(title: "Reading…", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        return placeholder
    }

    /// The owner's rows for the code domains: labels only, a record's code is
    /// asked for when it is clicked. A failure leaves the placeholder.
    private func fetchCodes(_ submenu: NSMenu) {
        Thread.detachNewThread {
            let reply = try? OwnerClient.call(["action": "menu_codes"])
            guard let entries = reply?["entries"] as? [[String: Any]] else { return }
            // vault §8.1: a header row names its vault and carries its mark; code rows carry none.
            let domains = Set(entries.compactMap { $0["vault"] as? String })
            var looks: [String: NSImage] = [:]
            for domain in domains { looks[domain] = VaultLook.image(domain: domain) }
            DispatchQueue.main.async {
                submenu.removeAllItems()
                for entry in entries {
                    let item = self.menuItem(entry)
                    if let domain = entry["vault"] as? String { item.image = looks[domain] }
                    submenu.addItem(item)
                }
            }
        }
    }

    /// Fetched when the submenu is drawn, at most once per stats interval; a
    /// failure leaves the placeholder.
    private func fillStats(_ submenu: NSMenu) {
        let placeholder = NSMenuItem(title: "Reading…", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        let entries = statsEntries
        if let entries = entries, !entries.isEmpty {
            for entry in entries {
                let line = NSMenuItem(title: entry["label"] as? String ?? "", action: nil, keyEquivalent: "")
                line.isEnabled = false
                submenu.addItem(line)
            }
        } else {
            submenu.addItem(placeholder)
        }
        guard Date().timeIntervalSince(statsFetched) >= Self.statsInterval else { return }
        statsFetched = Date()
        Thread.detachNewThread {
            let reply = try? OwnerClient.call(["action": "menu_stats"])
            guard let entries = reply?["entries"] as? [[String: Any]] else { return }
            DispatchQueue.main.async {
                self.statsEntries = entries
                submenu.removeAllItems()
                for entry in entries {
                    let line = NSMenuItem(
                        title: entry["label"] as? String ?? "", action: nil, keyEquivalent: "")
                    line.isEnabled = false
                    submenu.addItem(line)
                }
            }
        }
    }

    @objc private func act(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? [String: Any] else { return }
        if let name = action["openFolder"] as? String {
            withRoot(of: name) { NSWorkspace.shared.open($0) }
        } else if let reveal = action["reveal"] as? [String: Any],
            let name = reveal["domain"] as? String, let rel = reveal["rel"] as? String
        {
            withRoot(of: name) {
                NSWorkspace.shared.activateFileViewerSelecting([$0.appendingPathComponent(rel)])
            }
        } else if let paused = action["setPaused"] as? Bool {
            // The state shown is read back by the next poll.
            pause(paused)
        } else if let copy = action["copyCode"] as? [String: Any],
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

/// security-model §10.6: a secret's field, masked until its Show box is
/// checked; the box starts unchecked each time the field is made.
final class SecretField: NSView {
    static let fieldHeight: CGFloat = 24
    static let height: CGFloat = fieldHeight + 22

    let masked = NSSecureTextField()
    private let clear = NSTextField()
    private let show = NSButton(checkboxWithTitle: "Show", target: nil, action: nil)

    init(placeholder: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: Self.height))
        for field in [masked, clear] as [NSTextField] {
            field.placeholderString = placeholder
            field.isAutomaticTextCompletionEnabled = false
            field.autoresizingMask = [.width]
            addSubview(field)
        }
        clear.isHidden = true
        show.target = self
        show.action = #selector(toggle)
        addSubview(show)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let width = bounds.width
        masked.frame = NSRect(x: 0, y: bounds.height - Self.fieldHeight, width: width, height: Self.fieldHeight)
        clear.frame = masked.frame
        show.frame = NSRect(x: 0, y: 0, width: width, height: 18)
    }

    var stringValue: String {
        get { show.state == .on ? clear.stringValue : masked.stringValue }
        set {
            masked.stringValue = newValue
            clear.stringValue = newValue
        }
    }

    /// The field typed into now, for the dialog's first responder.
    var input: NSTextField { show.state == .on ? clear : masked }

    @objc private func toggle() {
        let shown = show.state == .on
        let value = shown ? masked.stringValue : clear.stringValue
        stringValue = value
        masked.isHidden = shown
        clear.isHidden = show.state != .on
        window?.makeFirstResponder(input)
    }
}
