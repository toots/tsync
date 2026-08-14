import AppKit
import FileProvider
import Foundation
import os

private let log = Logger(subsystem: "org.feverdreamtv.tsync", category: "menu")

/// The menu bar item: an icon whose glyph says what tsync is doing, and a menu
/// listing the files in flight.
///
/// It decides none of that. The daemon answers `menu` with the icon, the tooltip
/// and every row, rendered from the same model the Linux tray links, so the two
/// platforms cannot say different things about the same state. What is left here
/// is what only this process can do: turn a row into an `NSMenuItem`, and turn a
/// domain and a relative path into a place on disk — which means asking the File
/// Provider, since where a domain's folder was surfaced is the system's answer to
/// give, not the daemon's.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let clients: [DaemonClient]
    private var menu: DaemonMenu?
    private var timer: Timer?

    private static let pollInterval: TimeInterval = 3
    private static let iconSide: CGFloat = 32

    /// Where each domain's folder is, asked of the system once: the Finder name
    /// is derived from the display name by rules that are not ours to guess.
    private var domainURLs: [String: URL] = [:]

    /// Rebuilding under an open menu would dismiss it. Rows hold still for as
    /// long as it is up.
    private var isOpen = false

    override init() { fatalError("use init(domains:)") }

    init(domains: [String]) {
        clients = domains.map { DaemonClient(domain: $0) }
        super.init()
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
        Task { await findDomainFolders() }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Polling

    /// One call, not one per domain: this daemon serves them all over the one
    /// socket, and the summary and the icon are decided across the set.
    private func poll() {
        guard let client = clients.first else { return }
        Task {
            let fresh = try? await client.menu()
            await MainActor.run {
                if let fresh { self.menu = fresh }
                self.render()
            }
        }
    }

    private func findDomainFolders() async {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        var found: [String: URL] = [:]
        for domain in domains {
            guard let manager = NSFileProviderManager(for: domain),
                  let url = try? await manager.getUserVisibleURL(for: .rootContainer)
            else { continue }
            found[domain.displayName] = url
        }
        let resolved = found
        await MainActor.run {
            self.domainURLs = resolved
            self.render()
        }
    }

    // MARK: - Resolving a row's target

    private func folderURL(_ domain: String) -> URL? { domainURLs[domain] }

    private func fileURL(_ target: DaemonMenuAction.Target) -> URL? {
        guard let root = domainURLs[target.domain] else { return nil }
        return root.appending(path: target.rel)
    }

    // MARK: - Rendering

    /// The daemon names icons the way a Linux panel looks them up, and the
    /// asset catalog carries an image set under each of those names — so there
    /// is no mapping table here, and a fifth state needs only a fifth imageset.
    /// An unknown name falls back to idle rather than to no icon at all: a menu
    /// bar extra with a nil image is a dead gap the user cannot click.
    private static func statusImage(named name: String) -> NSImage? {
        let image = NSImage(named: name) ?? NSImage(named: "tsync-idle-symbolic")
        // Template, so AppKit paints it black on a light menu bar and white on
        // a dark one instead of drawing our own colour into both.
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        image?.accessibilityDescription = "tsync"
        return image
    }

    private func render() {
        guard !isOpen else { return }

        item.button?.image = Self.statusImage(named: menu?.icon ?? "")
        item.button?.toolTip = menu?.tooltip

        let built = NSMenu()
        // Off, or AppKit disables every item with no action and draws it grey —
        // which is how information ends up looking like a broken command.
        built.autoenablesItems = false
        built.delegate = self
        for row in menu?.rows ?? [] {
            built.addItem(row.isSeparator ? .separator() : self.entry(row))
        }
        item.menu = built
    }

    private func entry(_ row: DaemonMenuRow) -> NSMenuItem {
        let title = row.label ?? ""
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        // Enabled, but with nothing to do unless its action stands for
        // something: it takes a click without acting on it, and reads as text
        // rather than as something switched off.
        entry.isEnabled = row.enabled ?? true
        let indent = row.indent ?? 0
        entry.indentationLevel = indent

        if let checked = row.checked { entry.state = checked ? .on : .off }

        if let action = row.action {
            if let domain = action.openFolder, let url = folderURL(domain) {
                entry.action = #selector(openInFinder)
                entry.target = self
                entry.representedObject = url
                entry.toolTip = url.path(percentEncoded: false)
            } else if let target = action.reveal, let url = fileURL(target) {
                entry.action = #selector(revealInFinder)
                entry.target = self
                entry.representedObject = url
                entry.toolTip = url.path(percentEncoded: false)
                entry.image = Self.icon(forFileNamed: title)
            } else if action.setPaused != nil {
                entry.action = #selector(togglePause)
                entry.target = self
            } else if action.quit == true {
                entry.action = #selector(NSApplication.terminate(_:))
                entry.keyEquivalent = "q"
            }
        }

        // A submenu the daemon has not filled in yet still has to open as one,
        // or the row moves under the pointer once it does.
        if row.submenu == true { entry.submenu = NSMenu() }

        // The deliberate grey for a detail under a heading, as opposed to the
        // one AppKit applies to anything it thinks is unavailable.
        entry.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: indent > 0 ? NSColor.secondaryLabelColor
                                             : NSColor.labelColor,
            ])
        return entry
    }

    private static func icon(forFileNamed name: String) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: NSTemporaryDirectory() + "/" + name)
        image.size = NSSize(width: Self.iconSide, height: Self.iconSide)
        return image
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) { isOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        render()
    }

    // MARK: - Actions

    /// A Finder window rooted at the folder. Not [NSWorkspace.open], which is
    /// this app opening a folder the sandbox never granted it: asking the Finder
    /// to show it is a request, and the access is the Finder's own.
    ///
    /// [getUserVisibleURL] answers with a security-scoped URL, and the claim has
    /// to be made before the path names anything — without it the call reports
    /// failure and nothing happens at all.
    @objc private func openInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let claimed = url.startAccessingSecurityScopedResource()
        defer { if claimed { url.stopAccessingSecurityScopedResource() } }
        let opened = NSWorkspace.shared.selectFile(
            nil, inFileViewerRootedAtPath: url.path(percentEncoded: false))
        if !opened {
            log.error("open '\(url.path, privacy: .public)': claimed=\(claimed)")
            // Naming it in its parent is the weaker gesture the Finder always
            // allows, so a click is never inert.
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// A file is selected in its folder instead: opening it would launch
    /// whatever owns the type, and may pull down a body that is still moving.
    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// One switch for every domain. The new state is not applied locally: the
    /// next poll reads it back, so the checkmark shows what the daemon did.
    @objc private func togglePause(_ sender: NSMenuItem) {
        let paused = sender.state != .on
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
