import AppKit
import OSLog

private let log = Logger(subsystem: "org.feverdreamtv.tsync", category: "StatusMenu")

/// What one domain's daemon last answered. `nil` counts mean it did not answer.
private struct DomainStatus {
    let name: String
    var uploads: Int?
    var downloads: Int?
    var paused: Bool?

    var reachable: Bool { uploads != nil }
    var isTransferring: Bool { (uploads ?? 0) + (downloads ?? 0) > 0 }

    var detail: String {
        guard let uploads, let downloads else { return "not answering" }
        switch (uploads, downloads) {
            case (0, 0): return paused == true ? "Paused" : "Idle"
            case (let up, 0): return "Uploading \(up)"
            case (0, let down): return "Downloading \(down)"
            case (let up, let down): return "Uploading \(up) · Downloading \(down)"
        }
    }
}

/// The menu-bar icon and its dropdown: per-domain transfer counts, and one
/// switch that pauses uploads everywhere.
///
/// Polled rather than pushed — the daemon publishes events for content changes,
/// not for queue depth, and a status call costs one socket round trip.
@MainActor
final class StatusMenu {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let clients: [DaemonClient]
    private var statuses: [DomainStatus]
    private var timer: Timer?

    private static let pollInterval: TimeInterval = 3

    init(domains: [String]) {
        clients = domains.map { DaemonClient(domain: $0) }
        statuses = domains.map { DomainStatus(name: $0) }
        item.menu = NSMenu()
        render()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval,
                                         repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // The counts are ambient information; letting the system coalesce this
        // with other wakeups matters more than hitting the interval.
        timer.tolerance = 1
        self.timer = timer
        poll()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Polling

    private func poll() {
        let clients = self.clients
        Task {
            var fresh: [DomainStatus] = []
            for client in clients {
                var status = DomainStatus(name: client.domain)
                // Per domain, so a restarting daemon or one wedged domain does
                // not blank the whole menu.
                if let response = try? await client.status() {
                    status.uploads = response.pendingUploads ?? 0
                    status.downloads = response.pendingDownloads ?? 0
                    status.paused = response.paused ?? false
                }
                fresh.append(status)
            }
            await MainActor.run {
                self.statuses = fresh
                self.render()
            }
        }
    }

    // MARK: - Rendering

    private var anyUnreachable: Bool { statuses.contains { !$0.reachable } }
    private var allPaused: Bool {
        !statuses.isEmpty && statuses.allSatisfy { $0.paused == true }
    }

    private var summary: String {
        guard !statuses.isEmpty else { return "No domains configured" }
        if anyUnreachable && statuses.allSatisfy({ !$0.reachable }) {
            return "Daemon not running"
        }
        let uploads = statuses.compactMap(\.uploads).reduce(0, +)
        let downloads = statuses.compactMap(\.downloads).reduce(0, +)
        if uploads == 0 && downloads == 0 { return allPaused ? "Paused" : "Idle" }
        var parts: [String] = []
        if uploads > 0 { parts.append("Uploading \(uploads)") }
        if downloads > 0 { parts.append("Downloading \(downloads)") }
        if allPaused { parts.append("paused") }
        return parts.joined(separator: " · ")
    }

    private var symbolName: String {
        if statuses.allSatisfy({ !$0.reachable }) { return "exclamationmark.triangle" }
        if allPaused { return "pause.circle" }
        if statuses.contains(where: \.isTransferring) { return "arrow.up.arrow.down" }
        return "arrow.triangle.2.circlepath"
    }

    private func render() {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "tsync")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "tsync — \(summary)"

        let menu = NSMenu()
        menu.addItem(disabled("tsync — \(summary)"))
        if !statuses.isEmpty {
            menu.addItem(.separator())
            for status in statuses {
                menu.addItem(disabled("\(status.name) — \(status.detail)"))
            }
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Pause uploads",
                                action: #selector(togglePause),
                                keyEquivalent: "")
        toggle.target = self
        toggle.state = allPaused ? .on : .off
        toggle.isEnabled = !statuses.allSatisfy { !$0.reachable }
        menu.addItem(toggle)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit tsync",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    // MARK: - Actions

    /// One switch for every domain. The new state is not applied locally: the
    /// next poll reads it back, so the checkmark shows what the daemon did.
    @objc private func togglePause() {
        let paused = !allPaused
        let clients = self.clients
        Task {
            for client in clients {
                do { try await client.setPaused(paused) }
                catch {
                    log.error("pause '\(client.domain, privacy: .public)': \(error, privacy: .public)")
                }
            }
            await MainActor.run { self.poll() }
        }
    }
}
