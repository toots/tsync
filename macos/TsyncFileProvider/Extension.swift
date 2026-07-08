import FileProvider
import Foundation
import OSLog

private let log = Logger(subsystem: "com.toots.tsync", category: "Extension")

private final class NotifyListener: @unchecked Sendable {
    private let domain: NSFileProviderDomain
    private var serverFD: Int32 = -1
    private let path = Config.groupContainerURL.appendingPathComponent("tsync/notify.sock").path

    init(domain: NSFileProviderDomain) {
        self.domain = domain
        try? FileManager.default.removeItem(atPath: path)
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, cstr, 104) }
            }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0 && listen(serverFD, 5) == 0
        guard ok else { close(serverFD); serverFD = -1; return }
        Thread.detachNewThread { self.acceptLoop() }
    }

    deinit {
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func acceptLoop() {
        while serverFD >= 0 {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else { continue }
            Thread.detachNewThread { self.handle(clientFD) }
        }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { return }
        let line = String(bytes: buf.prefix(n), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let manager = NSFileProviderManager(for: domain) else { return }
        if line.hasPrefix("EVICT ") {
            let key = String(line.dropFirst(6))
            manager.evictItem(identifier: NSFileProviderItemIdentifier(key)) { _ in }
        } else if line.hasPrefix("RESTORE ") {
            let key = String(line.dropFirst(8))
            manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(key)) { url, _ in
                guard let url else { return }
                // A coordinated read forces fileproviderd to materialize the item.
                var error: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { _ in }
            }
        } else if line.hasPrefix("UPLOADED ") {
            let key = String(line.dropFirst(9))
            manager.signalEnumerator(for: NSFileProviderItemIdentifier(key)) { _ in }
        } else if line.hasPrefix("CHANGED ") {
            let key = String(line.dropFirst(8))
            // Drop any stale materialized copy, then drive enumerateChanges via the working
            // set — signaling the specific key can't introduce items the DB has never seen.
            manager.evictItem(identifier: NSFileProviderItemIdentifier(key)) { _ in }
            manager.signalEnumerator(for: .workingSet) { _ in }
        } else if line == "RESYNC" {
            // Force fileproviderd to re-scan the whole tree, picking up changes
            // made directly in the bucket (which write no journal entry).
            manager.reimportItems(below: .rootContainer) { _ in }
        }
    }
}

final class TsyncExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    let domain: NSFileProviderDomain
    let config: Config
    private var notifyListener: NotifyListener?

    private static let startupAnchor = NSFileProviderSyncAnchor(
        "\(Date().timeIntervalSinceReferenceDate)".data(using: .utf8)!
    )

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.config = (try? Config.load()) ?? Config(versioning: false, domains: [])
        super.init()
        notifyListener = NotifyListener(domain: domain)
        log.info("init: domain=\(domain.identifier.rawValue, privacy: .public)")
    }

    func invalidate() {
        notifyListener = nil
        log.info("invalidate: domain=\(self.domain.identifier.rawValue, privacy: .public)")
    }

    // MARK: - NSFileProviderReplicatedExtension

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                completionHandler(try await resolveItem(identifier), nil)
            } catch {
                completionHandler(nil, IPC.fileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        Task {
            let key = itemIdentifier.rawValue
            log.info("fetchContents: \(key, privacy: .public)")
            do {
                let resp = try await IPC.ensureCached(key: key)
                guard let localPath = resp.localPath else { throw IPC.IPCError.badResponse }
                let item = try await resolveItem(itemIdentifier, isDownloaded: true)
                progress.completedUnitCount = 100
                completionHandler(URL(fileURLWithPath: localPath), item, nil)
            } catch {
                log.error("fetchContents error: \(key, privacy: .public): \(error, privacy: .public)")
                completionHandler(nil, nil, IPC.fileProviderError(error))
            }
        }
        return progress
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        Task {
            do {
                let key = s3Key(for: itemTemplate)
                let isDirectory = itemTemplate.contentType == .folder

                if isDirectory {
                    let dirKey = key + "/"
                    _ = try await IPC.mkdir(key: dirKey)
                    completionHandler(TsyncItem.make(key: dirKey, domainPrefix: domainPrefix), [], false, nil)
                } else if itemTemplate.contentType == .symbolicLink {
                    guard let target = itemTemplate.symlinkTargetPath ?? nil else {
                        throw IPC.IPCError.badResponse
                    }
                    let resp = try await IPC.symlink(key: key, target: target)
                    completionHandler(
                        TsyncItem.make(key: key, domainPrefix: domainPrefix,
                                       size: resp.size,
                                       modificationDate: resp.mtime.map { Date(timeIntervalSince1970: $0) },
                                       etag: resp.etag, symlinkTarget: target),
                        [], false, nil)
                } else {
                    let staging = try url.map { try stageContent($0) }
                    defer { staging.map { try? FileManager.default.removeItem(at: $0) } }
                    let resp: IPCResponse
                    if let staging {
                        resp = try await IPC.writeFile(key: key, staging: staging)
                    } else {
                        resp = try await IPC.createFile(key: key)
                    }
                    completionHandler(makeItem(key: key, resp: resp, isDownloaded: url != nil), [], false, nil)
                }
                progress.completedUnitCount = 100
            } catch {
                completionHandler(nil, [], false, IPC.fileProviderError(error))
            }
        }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        Task {
            do {
                let oldKey = item.itemIdentifier.rawValue
                let newKey = s3Key(for: item)
                let isRename = changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier)
                let isDirectory = item.contentType == .folder

                if isDirectory {
                    let dirKey = newKey + "/"
                    if isRename && oldKey != dirKey {
                        _ = try await IPC.renameItem(src: oldKey, dst: newKey)
                    }
                    completionHandler(TsyncItem.make(key: dirKey, domainPrefix: domainPrefix), [], false, nil)
                } else if isRename && oldKey != newKey {
                    let resp: IPCResponse
                    if let contentURL = newContents {
                        let staging = try stageContent(contentURL)
                        defer { try? FileManager.default.removeItem(at: staging) }
                        resp = try await IPC.writeFile(key: newKey, staging: staging)
                        _ = try await IPC.deleteItem(key: oldKey)
                    } else {
                        resp = try await IPC.renameItem(src: oldKey, dst: newKey)
                    }
                    completionHandler(makeItem(key: newKey, resp: resp, isDownloaded: true), [], false, nil)
                } else if let contentURL = newContents, changedFields.contains(.contents) {
                    let staging = try stageContent(contentURL)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    let resp = try await IPC.writeFile(key: newKey, staging: staging)
                    completionHandler(makeItem(key: newKey, resp: resp, isDownloaded: true), [], false, nil)
                } else {
                    // Metadata-only change (tags, last-used date, etc.) — nothing to sync
                    completionHandler(try await resolveItem(item.itemIdentifier), [], false, nil)
                }
                progress.completedUnitCount = 100
            } catch {
                log.error("modifyItem error: \(error, privacy: .public)")
                completionHandler(nil, [], false, IPC.fileProviderError(error))
            }
        }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let key = identifier.rawValue
                _ = try await (key.hasSuffix("/") ? IPC.rmdir(key: key) : IPC.deleteItem(key: key))
                completionHandler(nil)
            } catch {
                completionHandler(IPC.fileProviderError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        TsyncEnumerator(
            containerIdentifier: containerItemIdentifier,
            domain: domain,
            config: config,
            startupAnchor: TsyncExtension.startupAnchor)
    }

    // MARK: - Helpers

    private var domainPrefix: String { config.domainPrefix(domain.displayName) }

    private func resolveItem(_ identifier: NSFileProviderItemIdentifier, isDownloaded: Bool = false) async throws -> TsyncItem {
        if identifier == .rootContainer {
            return TsyncItem.rootContainer(displayName: domain.displayName)
        }
        let key = identifier.rawValue
        if key.hasSuffix("/") {
            return TsyncItem.make(key: key, domainPrefix: domainPrefix)
        }
        return makeItem(key: key, resp: try await IPC.stat(key: key), isDownloaded: isDownloaded)
    }

    private func makeItem(key: String, resp: IPCResponse, isDownloaded: Bool) -> TsyncItem {
        TsyncItem.make(key: key, domainPrefix: domainPrefix,
                       size: resp.size,
                       modificationDate: resp.mtime.map { Date(timeIntervalSince1970: $0) },
                       etag: resp.etag, isDownloaded: isDownloaded,
                       isUploaded: resp.isUploaded ?? true,
                       symlinkTarget: resp.symlinkTarget)
    }

    private func s3Key(for item: NSFileProviderItem) -> String {
        // Parent key always ends in "/" (root maps to the domain prefix, dir keys keep their slash).
        let parentKey = ItemID.key(for: item.parentItemIdentifier, domainPrefix: domainPrefix)
        return parentKey + item.filename
    }

    private func stageContent(_ url: URL) throws -> URL {
        let stagingDir = Config.groupContainerURL.appendingPathComponent("tsync/staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let dest = stagingDir.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.linkItem(at: url, to: dest)
        } catch {
            try FileManager.default.copyItem(at: url, to: dest)
        }
        return dest
    }
}
