import FileProvider
import UniformTypeIdentifiers

/// file-browser-differences.md §2: a domain's files through the file system,
/// from the root the framework gives the app. Every call blocks on file
/// coordination: none is made on the main thread.
enum FileStore {
    static let firstListingPatience: TimeInterval = 30
    /// android.md §8.
    static let refreshPatience: TimeInterval = 20
    /// android-app.md §5.
    static let maxNameAttempts = 1000

    enum State { case onlineOnly, downloaded, waitingToUpload }

    struct Item: Identifiable, Hashable {
        let url: URL
        let name: String
        let isFolder: Bool
        let size: Int?
        let modified: Date?
        let state: State
        let type: UTType?
        /// differences §2: from the owner's listing; false when it did not answer.
        var pinned = false
        var pinnedUntil: Date?
        var id: URL { url }
    }

    private static let keys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey,
        .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey,
    ]

    static func manager(_ domain: String) -> NSFileProviderManager? {
        NSFileProviderManager(
            for: NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(domainIdentifier(domain)), displayName: domain))
    }

    /// The domain's root, kept accessible for the life of the process.
    static func root(_ domain: String) async throws -> URL {
        guard let manager = manager(domain) else { throw failure("\(domain) is not registered") }
        let root = try await manager.getUserVisibleURL(for: .rootContainer)
        _ = root.startAccessingSecurityScopedResource()
        return root
    }

    static func isWritable(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isWritableKey]).isWritable) ?? true
    }

    /// A folder the system has not enumerated yet fails to read until the
    /// extension has answered.
    static func list(_ folder: URL) async throws -> [Item] {
        let deadline = Date().addingTimeInterval(firstListingPatience)
        while true {
            do {
                return try read(folder)
            } catch {
                if isUnreachable(error) || Date() > deadline { throw error }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// The listing with the owner's pins over it.
    static func pinned(_ items: [Item], _ pins: [String: Date?]?) -> [Item] {
        guard let pins else { return items }
        return items.map { item in
            var item = item
            if let until = pins[item.name] {
                item.pinned = true
                item.pinnedUntil = until
            }
            return item
        }
    }

    static func read(_ folder: URL) throws -> [Item] {
        try coordinatedRead(folder) { url in
            try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        }
        .map(item)
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func item(_ url: URL) -> Item {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: Set(keys))
        let isFolder = values?.isDirectory ?? false
        let state: State
        if values?.ubiquitousItemIsUploaded == false {
            state = .waitingToUpload
        } else if !isFolder, values?.ubiquitousItemDownloadingStatus == .notDownloaded {
            state = .onlineOnly
        } else {
            state = .downloaded
        }
        return Item(
            url: url, name: values?.name ?? url.lastPathComponent, isFolder: isFolder,
            size: isFolder ? nil : values?.fileSize, modified: values?.contentModificationDate,
            state: state, type: values?.contentType)
    }

    static func newFolder(_ name: String, in folder: URL) throws {
        try coordinatedWrite(folder.appendingPathComponent(name, isDirectory: true), options: []) {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false)
        }
    }

    /// A picked file copied in, under the first name not taken; the name it
    /// was given.
    static func upload(_ source: URL, into folder: URL) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var taken: Error = failure("no name left for \(source.lastPathComponent)")
        for attempt in 0...maxNameAttempts {
            let name = numbered(source.lastPathComponent, attempt)
            do {
                try coordinated(
                    reading: source, writing: folder.appendingPathComponent(name), options: .forReplacing
                ) { from, to in
                    try FileManager.default.copyItem(at: from, to: to)
                }
                return name
            } catch where isTaken(error) {
                taken = error
            }
        }
        throw taken
    }

    /// android-app.md §5: `<stem> (<n>)<ext>`, `<ext>` from the last dot when
    /// that dot is not the first character.
    static func numbered(_ name: String, _ n: Int) -> String {
        guard n > 0 else { return name }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return "\(name[..<dot]) (\(n))\(name[dot...])"
        }
        return "\(name) (\(n))"
    }

    /// A rename or a move: refused onto a taken name.
    static func move(_ url: URL, to destination: URL) throws {
        var outer: NSError?
        var inner: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url, options: .forMoving, writingItemAt: destination, options: .forReplacing,
            error: &outer
        ) { from, to in
            do { try FileManager.default.moveItem(at: from, to: to) } catch { inner = error }
        }
        if let error = outer ?? inner { throw error }
    }

    static func delete(_ url: URL) throws {
        try coordinatedWrite(url, options: .forDeleting) { try FileManager.default.removeItem(at: $0) }
    }

    /// The bytes fetched, so that the preview opens at once.
    static func download(_ url: URL) throws {
        try coordinatedRead(url) { _ in () }
    }

    /// differences §2: the owner's copy and its pin, then the system's.
    @discardableResult
    static func removeDownload(_ url: URL, domain: String) async throws -> String? {
        guard let manager = manager(domain) else { throw failure("\(domain) is not registered") }
        let identifier = try await identifier(url)
        let counts = try await owner(domain, "evict", ["ref": ref(identifier)])
        try await manager.evictItem(identifier: identifier)
        return counted(counts, "evicted")
    }

    /// The File Provider identifier, which is the owner's reference
    /// (file-provider.md §6.1).
    static func identifier(_ url: URL) async throws -> NSFileProviderItemIdentifier {
        try await withCheckedThrowingContinuation { done in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { identifier, _, error in
                if let identifier { return done.resume(returning: identifier) }
                done.resume(throwing: error ?? failure("no item for \(url.lastPathComponent)"))
            }
        }
    }

    static func ref(_ identifier: NSFileProviderItemIdentifier) -> String {
        identifier == .rootContainer ? "root" : identifier.rawValue
    }

    /// One request to the domain's owner through the service (ios.md §5.4),
    /// off the main thread.
    static func owner(_ domain: String, _ action: String, _ fields: [String: Any] = [:]) async throws
        -> [String: Any]
    {
        var request = fields
        request["action"] = action
        request["domain"] = domain
        let bulk = ["restore", "evict"].contains(action)
        return try await Task.detached { try OwnerClient.call(request, bulk: bulk) }.value
    }

    /// share: the URL and when it expires.
    static func shareLink(_ url: URL, domain: String) async throws -> (url: URL, expires: Date) {
        let reply = try await owner(domain, "share", ["ref": ref(try await identifier(url))])
        guard let link = (reply["url"] as? String).flatMap(URL.init(string:)),
            let expires = reply["expires"] as? Double
        else { throw failure("the owner's reply has no link") }
        return (link, Date(timeIntervalSince1970: expires))
    }

    /// restore: fetched and pinned; for a folder, how many files and how many failed.
    static func makeAvailableOffline(_ url: URL, domain: String) async throws -> String? {
        let counts = try await owner(domain, "restore", ["ref": ref(try await identifier(url))])
        return counted(counts, "restored")
    }

    /// file-browser.md §4: a folder's counts, said only when it was a walk.
    private static func counted(_ reply: [String: Any], _ done: String) -> String? {
        let n = reply[done] as? Int ?? 0, failed = reply["failed"] as? Int ?? 0
        guard n + failed > 1 else { return failed > 0 ? "it failed" : nil }
        return failed > 0 ? "\(n) files, \(failed) failed" : "\(n) files"
    }

    /// differences §2: the pinned children, from the owner's listing of the
    /// folder, by name, with when each pin ends; nil when the service does not
    /// answer.
    static func pins(_ folder: URL, domain: String) async -> [String: Date?]? {
        guard let identifier = try? await identifier(folder) else { return nil }
        var pins: [String: Date?] = [:]
        var after: String?
        repeat {
            var fields: [String: Any] = ["ref": ref(identifier), "pull": "never"]
            if let after { fields["after"] = after }
            guard let reply = try? await owner(domain, "list_dir", fields) else { return nil }
            for row in reply["items"] as? [[String: Any]] ?? [] {
                guard let name = row["name"] as? String else { continue }
                if row["availability"] as? String == "pinned" {
                    pins[name] = (row["pinnedUntil"] as? Double).map(Date.init(timeIntervalSince1970:))
                }
            }
            after = reply["next"] as? String
        } while after != nil
        return pins
    }

    /// ios.md §5.1: starts a refresh pass.
    static func signal(_ domain: String) {
        manager(domain)?.signalEnumerator(for: .workingSet) { _ in }
    }

    static func isTaken(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileWriteFileExists.rawValue
    }

    static func isUnreachable(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.serverUnreachable.rawValue {
            return true
        }
        return error.underlyingErrors.contains(where: isUnreachable)
    }

    private static func coordinatedRead<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var outer: NSError?
        var result: Result<T, Error> = .failure(failure("not read"))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &outer) { url in
            result = Result { try body(url) }
        }
        if let outer { throw outer }
        return try result.get()
    }

    private static func coordinatedWrite(
        _ url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void
    ) throws {
        var outer: NSError?
        var inner: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &outer) {
            do { try body($0) } catch { inner = error }
        }
        if let error = outer ?? inner { throw error }
    }

    private static func coordinated(
        reading source: URL, writing destination: URL, options: NSFileCoordinator.WritingOptions,
        _ body: (URL, URL) throws -> Void
    ) throws {
        var outer: NSError?
        var inner: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: source, options: .withoutChanges, writingItemAt: destination, options: options,
            error: &outer
        ) { from, to in
            do { try body(from, to) } catch { inner = error }
        }
        if let error = outer ?? inner { throw error }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "tsync", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// file-browser-differences.md §2, kept current: the folder on screen, read
/// again when the system reports a change below it.
final class FolderWatcher: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let changed: () -> Void

    init(_ folder: URL, changed: @escaping () -> Void) {
        presentedItemURL = folder
        self.changed = changed
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() { NSFileCoordinator.removeFilePresenter(self) }

    func presentedItemDidChange() { changed() }
    func presentedSubitemDidChange(at url: URL) { changed() }
    func presentedSubitemDidAppear(at url: URL) { changed() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changed() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        changed()
        completionHandler(nil)
    }
}
