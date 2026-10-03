import AppKit
import FileProvider

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

    func menuWillOpen(_ menu: NSMenu) { isOpen = true }

    func menuDidClose(_ menu: NSMenu) {
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
            fillStats(submenu)
            item.submenu = submenu
            item.action = nil
        }
        return item
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
}
