import AppKit
import FileProvider
import ImageIO
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: "org.feverdreamtv.tsync", category: "StatusMenu")

/// What one domain's daemon last answered. `nil` counts mean it did not answer.
private struct DomainStatus {
    let name: String
    var uploads: Int?
    var downloads: Int?
    var paused: Bool?

    /// What workers are on right now, so it changes from poll to poll.
    var uploading: [DaemonUpload] = []
    /// Bytes this domain's queue still owes.
    var pendingBytes: Int64?
    /// Whole-process counters, repeated by every domain the daemon serves: one
    /// uplink is what a rate and an ETA are against.
    var bytesUploaded: Int64?
    var uploadBytesPerSec: Double?

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
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let clients: [DaemonClient]
    private var statuses: [DomainStatus]
    private var timer: Timer?

    private static let pollInterval: TimeInterval = 3
    private static let maxUploadingShown = 5
    private static let iconSide: CGFloat = 32

    /// Where each domain's folder is, asked of the system once: the Finder name
    /// is derived from the display name by rules that are not ours to guess.
    private var domainURLs: [String: URL] = [:]

    /// Previews by body path, and the paths already asked for, so one the daemon
    /// has no picture for is not re-requested every poll.
    private var thumbnails: [String: NSImage] = [:]
    private var thumbnailsAsked: Set<String> = []

    /// The rows a preview can still land in. A menu on screen is the one built
    /// when it was opened, so a later [item.menu] never reaches it — the row's
    /// own image does.
    private var rows: [String: NSMenuItem] = [:]

    /// Rebuilding under an open menu would dismiss it. Counts hold still for as
    /// long as it is up; the pictures do not have to.
    private var isOpen = false


    override init() { fatalError("use init(domains:)") }

    init(domains: [String]) {
        clients = domains.map { DaemonClient(domain: $0) }
        statuses = domains.map { DomainStatus(name: $0) }
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
                    status.uploading = response.uploading ?? []
                    status.pendingBytes = response.pendingBytes
                    status.bytesUploaded = response.bytesUploaded
                    status.uploadBytesPerSec = response.uploadBytesPerSec
                }
                fresh.append(status)
            }
            await MainActor.run {
                self.statuses = fresh
                self.forgetThumbnails(outside: fresh)
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

    /// The file itself, under its domain's folder.
    private func fileURL(_ upload: DaemonUpload, in domain: String) -> URL? {
        guard let root = domainURLs[domain] else { return nil }
        return root.appending(path: upload.rel)
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

    /// Bytes are the domains' own; the rate and the running total are the
    /// daemon's, so they are read once rather than summed.
    private var pendingBytes: Int64 { statuses.compactMap(\.pendingBytes).reduce(0, +) }
    private var bytesUploaded: Int64? { statuses.compactMap(\.bytesUploaded).first }
    private var uploadRate: Double? { statuses.compactMap(\.uploadBytesPerSec).first }

    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let eta: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    private static func human(_ count: Int64) -> String {
        bytes.string(fromByteCount: count)
    }

    /// "223.2 MB sent · 12.8 GB to go", or just what has been sent once the
    /// queue is empty.
    private var trafficLine: String? {
        guard let bytesUploaded else { return nil }
        let sent = "\(Self.human(bytesUploaded)) sent"
        guard pendingBytes > 0 else { return sent }
        return "\(sent) · \(Self.human(pendingBytes)) to go"
    }

    /// "1.6 MB/s · 2h 14m left". No rate yet means no honest estimate, and a
    /// made-up one is worse than none.
    private var rateLine: String? {
        guard pendingBytes > 0, let rate = uploadRate, rate > 0 else { return nil }
        let speed = "\(Self.human(Int64(rate)))/s"
        let seconds = Double(pendingBytes) / rate
        guard let left = Self.eta.string(from: seconds), !left.isEmpty else {
            return "\(speed) · under a minute left"
        }
        return "\(speed) · \(left) left"
    }

    private var symbolName: String {
        if statuses.allSatisfy({ !$0.reachable }) { return "exclamationmark.triangle" }
        if allPaused { return "pause.circle" }
        if statuses.contains(where: \.isTransferring) { return "arrow.up.arrow.down" }
        return "arrow.triangle.2.circlepath"
    }

    private func render() {
        guard !isOpen else { return }
        rows.removeAll()
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "tsync")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "tsync — \(summary)"

        let menu = NSMenu()
        // Off, or AppKit disables every item with no action and draws it grey —
        // which is how information ends up looking like a broken command.
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(info("tsync — \(summary)"))
        if !statuses.isEmpty {
            menu.addItem(.separator())
            for status in statuses {
                menu.addItem(info("\(status.name) — \(status.detail)",
                                  opens: domainURLs[status.name]))
                // Capped: the queue runs a handful at a time, but a wide fan-out
                // must not push the rest of the menu off the screen.
                let shown = status.uploading.sorted { $0.name < $1.name }
                for upload in shown.prefix(Self.maxUploadingShown) {
                    let row = info(upload.name, secondary: true,
                                   icon: preview(of: upload, in: status.name),
                                   indent: 1,
                                   opens: fileURL(upload, in: status.name),
                                   reveals: true)
                    if let body = upload.body { rows[body] = row }
                    menu.addItem(row)
                }
                let hidden = status.uploading.count - Self.maxUploadingShown
                if hidden > 0 {
                    menu.addItem(info("… and \(hidden) more", secondary: true, indent: 1))
                }
            }
        }

        if let trafficLine {
            menu.addItem(.separator())
            menu.addItem(info(trafficLine))
            if let rateLine { menu.addItem(info(rateLine, secondary: true)) }
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

    /// A row that states something rather than doing something.
    ///
    /// [secondary] dims the detail under a heading — the deliberate grey, as
    /// opposed to the one AppKit applies to anything it thinks is unavailable.
    private func info(_ title: String, secondary: Bool = false,
                      icon: NSImage? = nil, indent: Int = 0,
                      opens: URL? = nil, reveals: Bool = false) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        // Enabled, but with nothing to do unless it stands for something on
        // disk: it takes a click without acting on it, and reads as text rather
        // than as something switched off.
        entry.isEnabled = true
        if let opens {
            entry.action = reveals ? #selector(revealInFinder) : #selector(openInFinder)
            entry.target = self
            entry.representedObject = opens
            entry.toolTip = opens.path(percentEncoded: false)
        }
        entry.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: secondary ? NSColor.secondaryLabelColor
                                            : NSColor.labelColor,
            ])
        entry.image = icon
        entry.indentationLevel = indent
        return entry
    }

    /// A picture of the file once the daemon has handed over enough of it, and
    /// the document icon meanwhile. The fetch is asynchronous, so the poll that
    /// first shows a file shows its icon and a later render swaps in the
    /// picture.
    private func preview(of upload: DaemonUpload, in domain: String) -> NSImage {
        guard let path = upload.body else { return Self.icon(forFileNamed: upload.name) }
        if let ready = thumbnails[path] { return ready }
        requestThumbnail(at: path, from: domain)
        return Self.icon(forFileNamed: upload.name)
    }

    private func requestThumbnail(at path: String, from domain: String) {
        guard thumbnailsAsked.insert(path).inserted else { return }
        guard let client = clients.first(where: { $0.domain == domain }) else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        Task {
            do {
                let picture = try await client.preview(path: path)
                guard let picture,
                      let image = Self.thumbnail(from: picture, scale: scale)
                else { return }  // Answered with nothing to show: no point asking again.
                await MainActor.run { self.show(image, for: path) }
            } catch {
                // The upload can finish between the listing and this request,
                // which the daemon answers as a path it no longer holds. Let a
                // later render ask again rather than settling for the icon.
                await MainActor.run { self.thumbnailsAsked.remove(path) }
            }
        }
    }

    /// Straight into the row when there is one, so a picture arriving under an
    /// open menu still appears in it.
    private func show(_ image: NSImage, for path: String) {
        thumbnails[path] = image
        if let row = rows[path] { row.image = image } else { render() }
    }

    /// The head of a file rather than all of it: a camera or scanner stores a
    /// small copy near the front, which is what this lifts. Nothing to decode at
    /// full size, and nothing that needs the rest of a 90 MB photo.
    nonisolated private static func thumbnail(from head: Data, scale: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(head as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: iconSide * scale,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                               options as CFDictionary)
        else { return nil }
        // Fitted in the square rather than filling it, or every non-square
        // picture is drawn stretched.
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        let longest = max(width, height, 1)
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: iconSide * width / longest,
                                    height: iconSide * height / longest))
    }

    /// Bounded by what is in flight: a long backlog would otherwise accumulate a
    /// picture per file uploaded since launch.
    private func forgetThumbnails(outside fresh: [DomainStatus]) {
        let live = Set(fresh.flatMap { $0.uploading.compactMap(\.body) })
        thumbnails = thumbnails.filter { live.contains($0.key) }
        thumbnailsAsked.formIntersection(live)
    }

    /// The document icon the Finder would show, from the name alone.
    ///
    /// Stands in until a preview arrives, and for anything ImageIO cannot make a
    /// picture of.
    private static func icon(forFileNamed name: String) -> NSImage {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        let image = NSWorkspace.shared.icon(for: type ?? .data)
        image.size = NSSize(width: Self.iconSide, height: Self.iconSide)
        return image
    }

    // MARK: - Actions

    func menuWillOpen(_ menu: NSMenu) { isOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        // Whatever the polls had to say while it was up.
        render()
    }

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
    /// whatever owns the type, and may pull down a body that is still uploading.
    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

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
