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
        } else if line.hasPrefix("UPLOADED ") {
            let key = String(line.dropFirst(9))
            manager.signalEnumerator(for: NSFileProviderItemIdentifier(key)) { _ in }
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
        self.config = (try? Config.load()) ?? Config(bucket: "", prefix: "", awsRegion: "", versioning: false, domains: [])
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
                completionHandler(nil, error)
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
            do {
                let key = itemIdentifier.rawValue
                let resp = try await IPC.ensureCached(key: key)
                guard let localPath = resp.localPath else { throw IPC.IPCError.badResponse }
                let item = try await resolveItem(itemIdentifier, isDownloaded: true)
                progress.completedUnitCount = 100
                completionHandler(URL(fileURLWithPath: localPath), item, nil)
                try? await IPC.evictItem(key: key)
            } catch {
                completionHandler(nil, nil, error)
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
                    let item = TsyncItem(
                        identifier: NSFileProviderItemIdentifier(dirKey),
                        parent: itemTemplate.parentItemIdentifier,
                        filename: itemTemplate.filename, isDirectory: true)
                    completionHandler(item, [], false, nil)
                } else {
                    let staging = try url.map { try stageContent($0) }
                    defer { staging.map { try? FileManager.default.removeItem(at: $0) } }
                    let resp: IPCResponse
                    if let staging {
                        resp = try await IPC.writeFile(key: key, staging: staging)
                    } else {
                        resp = try await IPC.createFile(key: key)
                    }
                    completionHandler(makeItem(identifier: NSFileProviderItemIdentifier(key),
                                               parent: itemTemplate.parentItemIdentifier,
                                               filename: itemTemplate.filename,
                                               resp: resp, isDownloaded: url != nil), [], false, nil)
                }
                progress.completedUnitCount = 100
            } catch {
                completionHandler(nil, [], false, error)
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
                    completionHandler(TsyncItem(
                        identifier: NSFileProviderItemIdentifier(dirKey),
                        parent: item.parentItemIdentifier,
                        filename: item.filename, isDirectory: true), [], false, nil)
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
                    completionHandler(makeItem(
                        identifier: NSFileProviderItemIdentifier(newKey),
                        parent: item.parentItemIdentifier,
                        filename: item.filename, resp: resp, isDownloaded: true), [], false, nil)
                } else if let contentURL = newContents, changedFields.contains(.contents) {
                    let staging = try stageContent(contentURL)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    let resp = try await IPC.writeFile(key: newKey, staging: staging)
                    completionHandler(makeItem(
                        identifier: NSFileProviderItemIdentifier(newKey),
                        parent: item.parentItemIdentifier,
                        filename: item.filename, resp: resp, isDownloaded: true), [], false, nil)
                } else {
                    // Metadata-only change (tags, last-used date, etc.) — nothing to sync
                    completionHandler(try await resolveItem(item.itemIdentifier), [], false, nil)
                }
                progress.completedUnitCount = 100
            } catch {
                log.error("modifyItem error: \(error, privacy: .public)")
                completionHandler(nil, [], false, error)
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
                completionHandler(error)
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

    private func resolveItem(_ identifier: NSFileProviderItemIdentifier, isDownloaded: Bool = false) async throws -> TsyncItem {
        if identifier == .rootContainer {
            return TsyncItem.rootContainer(displayName: domain.displayName)
        }
        let key = identifier.rawValue
        let domainPrefix = config.domainPrefix(domain.displayName)
        if key.hasSuffix("/") {
            let parent = TsyncItem.parentIdentifier(for: String(key.dropLast()), domainPrefix: domainPrefix)
            return TsyncItem(identifier: identifier, parent: parent,
                              filename: key.split(separator: "/").last.map(String.init) ?? key,
                              isDirectory: true)
        }
        let resp = try await IPC.stat(key: key)
        let parent = TsyncItem.parentIdentifier(for: key, domainPrefix: domainPrefix)
        return makeItem(identifier: identifier, parent: parent,
                         filename: key.split(separator: "/").last.map(String.init) ?? key,
                         resp: resp, isDownloaded: isDownloaded)
    }

    private func makeItem(identifier: NSFileProviderItemIdentifier,
                           parent: NSFileProviderItemIdentifier,
                           filename: String, resp: IPCResponse,
                           isDownloaded: Bool) -> TsyncItem {
        TsyncItem(identifier: identifier, parent: parent, filename: filename,
                   isDirectory: false,
                   size: resp.size,
                   modificationDate: resp.mtime.map { Date(timeIntervalSince1970: $0) },
                   etag: resp.etag,
                   isDownloaded: isDownloaded,
                   isUploaded: resp.isUploaded ?? true)
    }

    private func s3Key(for item: NSFileProviderItem) -> String {
        if item.parentItemIdentifier == .rootContainer {
            return config.domainPrefix(domain.displayName) + item.filename
        }
        let parentKey = item.parentItemIdentifier.rawValue
        return (parentKey.hasSuffix("/") ? parentKey : parentKey + "/") + item.filename
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
