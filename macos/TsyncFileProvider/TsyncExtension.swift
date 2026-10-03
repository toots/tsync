import AppKit
import FileProvider
import UniformTypeIdentifiers

/// The File Provider callbacks (§6.5): each one asks the owner and translates.
/// No rule is decided here, and nothing is kept between callbacks.
final class TsyncExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderCustomAction,
    NSFileProviderPartialContentFetching
{
    let domain: NSFileProviderDomain
    let owner: Owner

    /// §13 progress_poll_interval.
    static let progressPollInterval: TimeInterval = 0.5

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        owner = Owner(domain: domain.displayName)
        super.init()
    }

    func invalidate() {}

    private var manager: NSFileProviderManager? { NSFileProviderManager(for: domain) }

    // MARK: Items and enumeration

    /// The system's authority on existence: `noSuchItem` deletes the item from
    /// disk, so it answers the owner's `not_found` and nothing else.
    func item(
        for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let done = Once { (result: (NSFileProviderItem?, Error?)) in
            completionHandler(result.0, result.1)
        }
        return task(onCancel: { done((nil, Errors.map(OwnerFailure.cancelled, .read))) }) {
            [owner] c, _ in
            do {
                let reply = try owner.call("stat", ["ref": ItemRef.ref(identifier)], cancellation: c)
                done((Item(try Owner.row(reply, nested: false)), nil))
            } catch {
                done((nil, Errors.map(error, .read, missing: identifier)))
            }
        }
    }

    /// Creating an enumerator does no I/O.
    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        switch containerItemIdentifier {
        case .workingSet: return WorkingSetEnumerator(owner: owner)
        case .trashContainer: return TrashEnumerator()
        default: return DirectoryEnumerator(owner: owner, ref: ItemRef.ref(containerItemIdentifier))
        }
    }

    // MARK: Contents

    /// The owner writes the file into the provider's temporary directory, since
    /// the extension may not move files there; the reply's item describes
    /// exactly the bytes written.
    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let done = Once { (result: (URL?, NSFileProviderItem?, Error?)) in
            completionHandler(result.0, result.1, result.2)
        }
        let ref = ItemRef.ref(itemIdentifier)
        return task(onCancel: { done((nil, nil, Errors.map(OwnerFailure.cancelled, .read))) }) {
            [owner, manager] c, progress in
            var dest: URL?
            do {
                guard let temp = try manager?.temporaryDirectoryURL() else {
                    throw OwnerFailure.transport("no temporary directory for the domain")
                }
                let url = temp.appendingPathComponent(UUID().uuidString)
                dest = url
                let finished = Flag()
                detached { Self.reportProgress(owner, ref, progress, until: finished) }
                defer { finished.set() }
                let reply = try owner.bulk(
                    "ensure_cached", ["ref": ref, "dest": url.path], cancellation: c)
                let row = try Owner.row(reply)
                progress.totalUnitCount = max(1, row.size)
                progress.completedUnitCount = progress.totalUnitCount
                done((url, Item(row), nil))
            } catch {
                if let dest = dest { try? FileManager.default.removeItem(at: dest) }
                done((nil, nil, Errors.map(error, .read, missing: itemIdentifier)))
            }
        }
    }

    private static func reportProgress(_ owner: Owner, _ ref: String, _ progress: Progress, until finished: Flag) {
        while !finished.isSet {
            if let reply = try? owner.call("download_progress", ["ref": ref]),
                reply["active"] as? Bool == true
            {
                let total = (reply["totalBytes"] as? NSNumber)?.int64Value ?? 0
                let got = (reply["bytesDownloaded"] as? NSNumber)?.int64Value ?? 0
                if total > 0 { progress.totalUnitCount = total }
                progress.completedUnitCount = got
            }
            Thread.sleep(forTimeInterval: progressPollInterval)
        }
    }

    func fetchPartialContents(
        for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion,
        request: NSFileProviderRequest, minimalRange requestedRange: NSRange, aligningTo alignment: Int,
        options: NSFileProviderFetchContentsOptions,
        completionHandler: @escaping (
            URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?
        ) -> Void
    ) -> Progress {
        let done = Once { (result: (URL?, NSFileProviderItem?, NSRange, Error?)) in
            completionHandler(result.0, result.1, result.2, [], result.3)
        }
        let none = NSRange(location: 0, length: 0)
        let gone = Errors.provider(
            .versionNoLongerAvailable, OwnerFailure.transport("the version changed"))
        let ref = ItemRef.ref(itemIdentifier)
        return task(onCancel: { done((nil, nil, none, Errors.map(OwnerFailure.cancelled, .read))) }) { [owner, manager] c, _ in
            var dest: URL?
            do {
                let stat = try Owner.row(
                    owner.call("stat", ["ref": ref], cancellation: c), nested: false)
                if options.contains(.strictVersioning)
                    && stat.contentVersion != requestedVersion.contentVersion
                {
                    return done((nil, nil, none, gone))
                }
                let range = alignedRange(
                    requestedRange, alignment: alignment, documentSize: stat.size)
                // An empty range is invalid to the owner, and an unknown error
                // would be retried forever.
                if range.length == 0 {
                    return done((nil, nil, none, gone))
                }
                guard let temp = try manager?.temporaryDirectoryURL() else {
                    throw OwnerFailure.transport("no temporary directory for the domain")
                }
                let url = temp.appendingPathComponent(UUID().uuidString)
                dest = url
                let reply = try owner.bulk(
                    "fetch_range",
                    [
                        "ref": ref, "dest": url.path, "offset": range.start,
                        "length": range.length,
                    ], cancellation: c)
                let row = try Owner.row(reply)
                // The content changed in between: the range may be misaligned.
                if row.contentVersion != stat.contentVersion {
                    try? FileManager.default.removeItem(at: url)
                    return done((nil, nil, none, gone))
                }
                let offset = (reply["offset"] as? NSNumber)?.intValue ?? Int(range.start)
                let length = (reply["length"] as? NSNumber)?.intValue ?? Int(range.length)
                done((url, Item(row), NSRange(location: offset, length: length), nil))
            } catch {
                if let dest = dest { try? FileManager.default.removeItem(at: dest) }
                done((nil, nil, none, Errors.map(error, .read, missing: itemIdentifier)))
            }
        }
    }

    // MARK: Mutations

    /// The fields the owner stores; every other given field is returned as
    /// still pending, so the system never overwrites it from the reply.
    private static let stored: NSFileProviderItemFields = [.contents, .filename, .parentItemIdentifier]

    func createItem(
        basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
        options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?
        ) -> Void
    ) -> Progress {
        let done = Once { (result: (NSFileProviderItem?, NSFileProviderItemFields, Error?)) in
            completionHandler(result.0, result.1, false, result.2)
        }
        let parent = itemTemplate.parentItemIdentifier
        let place: [String: Any] = ["parentRef": ItemRef.ref(parent), "name": itemTemplate.filename]
        let type = itemTemplate.contentType ?? .data
        let isDirectory = type == .folder || (type.conforms(to: .directory) && url == nil)
        let mayExist = options.contains(.mayAlreadyExist)
        let pending = fields.subtracting(Self.stored)
        return task(onCancel: { done((nil, [], Errors.map(OwnerFailure.cancelled, .mutation))) }) {
            [owner, manager] c, _ in
            do {
                let row: Row
                if isDirectory {
                    var request = place
                    request["exclusive"] = !mayExist
                    row = try Owner.row(owner.call("mkdir", request, cancellation: c))
                } else if mayExist, let existing = try Self.existing(owner, place, c) {
                    if let url = url {
                        row = try Self.write(
                            owner, manager, url, ["ref": existing.ref], base: existing.contentId, c)
                    } else {
                        row = existing
                    }
                } else if type == .symbolicLink {
                    guard let target = itemTemplate.symlinkTargetPath ?? nil else {
                        throw OwnerFailure.refused(
                            code: "invalid", message: "a symbolic link needs a target", item: nil)
                    }
                    var request = place
                    request["target"] = target
                    request["exclusive"] = true
                    row = try Owner.row(owner.call("symlink", request, cancellation: c))
                } else if let url = url {
                    var request = place
                    request["exclusive"] = true
                    row = try Self.write(owner, manager, url, request, base: nil, c)
                } else {
                    var request = place
                    request["exclusive"] = true
                    row = try Owner.row(owner.call("create", request, cancellation: c))
                }
                done((Item(row), pending, nil))
            } catch {
                done((nil, [], Self.mutationError(error, missing: parent)))
            }
        }
    }

    /// The item already at a place, or nil when the owner answers `not_found`;
    /// any other error propagates (only `not_found` means absent).
    private static func existing(_ owner: Owner, _ place: [String: Any], _ c: Cancellation) throws -> Row? {
        do {
            return try Owner.row(owner.call("stat", place, cancellation: c), nested: false)
        } catch let failure as OwnerFailure where failure.code == "not_found" {
            return nil
        }
    }

    func modifyItem(
        _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields, contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?
        ) -> Void
    ) -> Progress {
        let done = Once { (result: (NSFileProviderItem?, NSFileProviderItemFields, Error?)) in
            completionHandler(result.0, result.1, false, result.2)
        }
        let identifier = item.itemIdentifier
        let ref = ItemRef.ref(identifier)
        let moved = changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier)
        let place: [String: Any] = [
            "ref": ref, "parentRef": ItemRef.ref(item.parentItemIdentifier), "name": item.filename,
            "noreplace": true,
        ]
        let base = String(data: version.contentVersion, encoding: .utf8)
        let pending = changedFields.subtracting(Self.stored)
        return task(onCancel: { done((nil, [], Errors.map(OwnerFailure.cancelled, .mutation))) }) {
            [owner, manager] c, _ in
            do {
                var row: Row?
                if moved {
                    row = try Owner.row(owner.call("rename", place, cancellation: c))
                }
                if changedFields.contains(.contents), let url = newContents {
                    row = try Self.write(owner, manager, url, ["ref": ref], base: base, c)
                }
                let result = try row
                    ?? Owner.row(owner.call("stat", ["ref": ref], cancellation: c), nested: false)
                done((Item(result), pending, nil))
            } catch {
                done((nil, [], Self.mutationError(error, missing: identifier)))
            }
        }
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let done = Once { (error: Error?) in completionHandler(error) }
        let ref = ItemRef.ref(identifier)
        return task(onCancel: { done(Errors.map(OwnerFailure.cancelled, .mutation)) }) {
            [owner] c, _ in
            do {
                if ref.hasPrefix("d:") {
                    if !options.contains(.recursive) {
                        let reply = try owner.call(
                            "list_dir", ["ref": ref, "limit": 1], cancellation: c)
                        if !(reply["items"] as? [Any] ?? []).isEmpty {
                            throw OwnerFailure.refused(
                                code: "not_empty", message: "the folder is not empty", item: nil)
                        }
                    }
                    _ = try owner.call("rmdir", ["ref": ref], cancellation: c)
                } else {
                    _ = try owner.call("delete", ["ref": ref], cancellation: c)
                }
                done(nil)
            } catch let failure as OwnerFailure where failure.code == "not_found" {
                done(nil)
            } catch {
                done(Self.mutationError(error, missing: identifier))
            }
        }
    }

    private static func mutationError(_ error: Error, missing: NSFileProviderItemIdentifier) -> NSError {
        var occupant: Item?
        if case .refused(_, _, let item?) = error as? OwnerFailure, let row = Row(item) {
            occupant = Item(row)
        }
        return Errors.map(error, .mutation, missing: missing, occupant: occupant)
    }

    /// §6.6: the system unlinks the contents URL once the callback completes, so
    /// the file is cloned (copied when cloning is impossible) into the staging
    /// directory and adopted by the owner by rename before it replies. No hard
    /// link: a second link on the system's file makes the item unevictable.
    private static func write(
        _ owner: Owner, _ manager: NSFileProviderManager?, _ url: URL, _ target: [String: Any],
        base: String?, _ c: Cancellation
    ) throws -> Row {
        guard let temp = try manager?.temporaryDirectoryURL() else {
            throw OwnerFailure.transport("no temporary directory for the domain")
        }
        let staging = temp.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let file = staging.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        if clonefile(url.path, file.path, 0) != 0 {
            try FileManager.default.copyItem(at: url, to: file)
        }
        var request = target
        request["staging"] = file.path
        if let base = base, base != "-" { request["base"] = base }
        return try Owner.row(owner.call("write", request, cancellation: c))
    }

    // MARK: Custom actions (§6.7)

    static let copyShareURL = "org.feverdreamtv.tsync.copyShareURL"
    static let makeAvailableOffline = "org.feverdreamtv.tsync.makeAvailableOffline"
    static let makeOnlineOnly = "org.feverdreamtv.tsync.makeOnlineOnly"

    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let done = Once { (error: Error?) in completionHandler(error) }
        let action = actionIdentifier.rawValue
        return task(onCancel: { done(Errors.map(OwnerFailure.cancelled, .mutation)) }) {
            [owner, manager] c, _ in
            switch action {
            case Self.copyShareURL:
                guard let first = itemIdentifiers.first else { return done(nil) }
                do {
                    let reply = try owner.call(
                        "share", ["ref": ItemRef.ref(first)], cancellation: c)
                    guard let url = reply["url"] as? String else {
                        throw OwnerFailure.transport("the owner's reply has no url")
                    }
                    DispatchQueue.main.sync {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                    done(nil)
                } catch {
                    done(Errors.map(error, .read))
                }
            case Self.makeAvailableOffline:
                done(Self.eachItem(itemIdentifiers) { identifier in
                    _ = try owner.bulk(
                        "restore", ["ref": ItemRef.ref(identifier)], cancellation: c)
                    if ItemRef.ref(identifier).hasPrefix("i:"), let manager = manager {
                        try Self.wait { manager.requestDownloadForItem(withIdentifier: identifier, requestedRange: nil, completionHandler: $0) }
                    }
                })
            case Self.makeOnlineOnly:
                done(Self.eachItem(itemIdentifiers) { identifier in
                    _ = try owner.bulk(
                        "evict", ["ref": ItemRef.ref(identifier)], cancellation: c)
                    if let manager = manager {
                        try Self.wait { manager.evictItem(identifier: identifier, completionHandler: $0) }
                    }
                })
            default:
                done(NSError(domain: NSCocoaErrorDomain, code: CocoaError.featureUnsupported.rawValue))
            }
        }
    }

    /// Every item is attempted; the failures are reported together.
    private static func eachItem(
        _ identifiers: [NSFileProviderItemIdentifier],
        _ body: (NSFileProviderItemIdentifier) throws -> Void
    ) -> Error? {
        var failures: [String] = []
        for identifier in identifiers {
            do { try body(identifier) } catch {
                failures.append("\(identifier.rawValue): \(error.localizedDescription)")
            }
        }
        if failures.isEmpty { return nil }
        return NSError(
            domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
            userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")])
    }

    /// A manager call made synchronous on this worker thread.
    private static func wait(_ call: (@escaping (Error?) -> Void) -> Void) throws {
        let finished = DispatchSemaphore(value: 0)
        var failure: Error?
        call { error in
            failure = error
            finished.signal()
        }
        finished.wait()
        if let failure = failure { throw failure }
    }
}

/// Completes a callback exactly once, whichever of the work and the
/// cancellation gets there first (§6.5).
final class Once<Value> {
    private let lock = NSLock()
    private var done = false
    private let handler: (Value) -> Void

    init(_ handler: @escaping (Value) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ value: Value) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { handler(value) }
    }
}

/// A flag set once from another thread.
final class Flag {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// A callback's work on its own thread, with a progress whose cancellation
/// cancels the request and completes the callback at once.
func task(onCancel: @escaping () -> Void, _ body: @escaping (Cancellation, Progress) -> Void) -> Progress {
    let progress = Progress(totalUnitCount: 1)
    let cancellation = Cancellation()
    progress.cancellationHandler = {
        cancellation.cancel()
        onCancel()
    }
    detached { body(cancellation, progress) }
    return progress
}
