import AppKit
import FileProvider
import Foundation
import OSLog

private let log = Logger(subsystem: "org.feverdreamtv.tsync", category: "Extension")

final class TsyncExtension: NSObject, NSFileProviderReplicatedExtension,
                            NSFileProviderPartialContentFetching, @unchecked Sendable {
    private let domain: NSFileProviderDomain
    private let client: DaemonClient
    private let readOnly: Bool
    private let materialized: MaterializedSet

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let config = (try? Config.load()) ?? Config(domains: [])
        self.readOnly = config.isReadOnly(domain.displayName)
        self.client = DaemonClient(domain: domain.displayName)
        self.materialized = MaterializedSet(domain: domain)
        super.init()
        log.info("init: \(domain.identifier.rawValue, privacy: .public)")
    }

    /// Nothing to tear down: this process holds no channel of its own. It
    /// connects out to the daemon, and change notification is the app's job,
    /// since the app runs when this does not.
    func invalidate() {
        log.info("invalidate: \(self.domain.identifier.rawValue, privacy: .public)")
    }

    // MARK: - Metadata

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let task = Task {
            do {
                completionHandler(try await resolve(identifier), nil)
            } catch {
                completionHandler(nil, FileProviderError.from(error, item: identifier))
            }
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    /// The system's authority on whether an item still exists, so a directory
    /// must be resolved against the daemon like anything else: answering from
    /// the identifier alone keeps a deleted folder on disk forever.
    private func resolve(_ identifier: NSFileProviderItemIdentifier) async throws -> TsyncItem {
        if identifier == .rootContainer {
            return TsyncItem.rootContainer(displayName: domain.displayName,
                                           readOnly: readOnly)
        }
        let item = try await client.stat(ItemID.wire(identifier))
        guard let built = TsyncItem.make(item, readOnly: readOnly) else {
            throw DaemonError.remote(code: "not_found", message: "unknown item")
        }
        return built
    }

    // MARK: - Contents

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: -1)
        let ref = ItemID.wire(itemIdentifier)
        let task = Task {
            // Polled before the first sleep, so the bar becomes determinate as
            // soon as the daemon knows the size. "Nothing running" leaves the
            // bar where it is: the work has not started or has just finished,
            // and resetting to indeterminate reads as a restarted transfer.
            let poller = Task {
                while !Task.isCancelled {
                    if let p = try? await client.downloadProgress(ref: ref),
                       p.active == true {
                        if let total = p.totalBytes, total > 0 {
                            progress.totalUnitCount = total
                        }
                        if let done = p.bytesDownloaded {
                            progress.completedUnitCount = done
                        }
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            defer { poller.cancel() }
            do {
                // The system takes ownership of the file, but this process may
                // not move one into that directory (EPERM, on locally signed and
                // notarised builds alike), so the daemon assembles it in place.
                guard let manager = NSFileProviderManager(for: domain),
                      let temporary = try? manager.temporaryDirectoryURL() else {
                    throw DaemonError.transport("no temporary directory for domain")
                }
                let destination = temporary.appendingPathComponent(UUID().uuidString)
                try await client.ensureCached(ref: ref, destination: destination.path)
                try Task.checkCancellation()
                // The last poll lands short of the end, and a bar vanishing at
                // 90% reads as an abandoned transfer.
                poller.cancel()
                if progress.totalUnitCount > 0 {
                    progress.completedUnitCount = progress.totalUnitCount
                }
                completionHandler(destination, try await resolve(itemIdentifier), nil)
            } catch is CancellationError {
                completionHandler(nil, nil, CocoaError(.userCancelled))
            } catch {
                log.error("fetchContents \(ref, privacy: .public): \(error, privacy: .public)")
                completionHandler(nil, nil, FileProviderError.from(error, item: itemIdentifier))
            }
        }
        // The system cancels a slow fetch and then expects the completion
        // handler promptly; without this it waits on an unanswered request.
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    /// Serve one range instead of the whole file, so opening a large file costs
    /// only the bytes the application touched. The system writes what we return
    /// into its own copy at that offset and comes back for more as it reads on.
    ///
    /// An optimisation on top of `fetchContents`, which the system still uses to
    /// materialize a file outright.
    func fetchPartialContents(for itemIdentifier: NSFileProviderItemIdentifier,
                              version requestedVersion: NSFileProviderItemVersion,
                              request: NSFileProviderRequest,
                              minimalRange requestedRange: NSRange,
                              aligningTo alignment: Int,
                              options: NSFileProviderFetchContentsOptions = [],
                              completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(max(0, requestedRange.length)))
        let ref = ItemID.wire(itemIdentifier)
        let task = Task {
            do {
                let item = try await resolve(itemIdentifier)
                // Strict versioning discards anything but the requested
                // version, so failing here lets the system re-ask for ours
                // instead of wasting the transfer.
                if options.contains(.strictVersioning),
                   item.itemVersion.contentVersion != requestedVersion.contentVersion {
                    throw NSError(domain: NSFileProviderErrorDomain,
                                  code: NSFileProviderError.versionNoLongerAvailable.rawValue)
                }

                let range = PartialRange.aligned(covering: requestedRange,
                                                 alignment: alignment,
                                                 documentSize: item.documentSize?.int64Value ?? 0)
                // Same EPERM constraint as the whole-file path.
                guard let manager = NSFileProviderManager(for: domain),
                      let temporary = try? manager.temporaryDirectoryURL() else {
                    throw DaemonError.transport("no temporary directory for domain")
                }
                let destination = temporary.appendingPathComponent(UUID().uuidString)
                let served = try await client.fetchRange(ref: ref,
                                                         destination: destination.path,
                                                         offset: Int64(range.location),
                                                         length: Int64(range.length))
                try Task.checkCancellation()
                progress.completedUnitCount = progress.totalUnitCount
                completionHandler(destination, item, served, [], nil)
            } catch is CancellationError {
                completionHandler(nil, nil, requestedRange, [], CocoaError(.userCancelled))
            } catch {
                log.error("fetchPartialContents \(ref, privacy: .public) \(requestedRange.location)+\(requestedRange.length): \(error, privacy: .public)")
                completionHandler(nil, nil, requestedRange, [],
                                  FileProviderError.from(error, item: itemIdentifier))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - Mutation

    /// Fields this side cannot store. Reporting them as still pending stops the
    /// system propagating its own idea of them to disk (which silently reverted
    /// Finder tags), and stops it re-offering them once a call reports back the
    /// same set it was given.
    private func unsupported(_ fields: NSFileProviderItemFields) -> NSFileProviderItemFields {
        fields.subtracting([.contents, .filename, .parentItemIdentifier])
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        if readOnly {
            completionHandler(nil, [], false, readOnlyError())
            return progress
        }
        let task = Task {
            let parent = ItemID.wire(itemTemplate.parentItemIdentifier)
            let name = itemTemplate.filename
            let pending = unsupported(fields)
            do {
                let isDirectory = itemTemplate.contentType == .folder
                // A reimport replays everything on disk through this call, and
                // re-writing a file that is already there would re-upload the
                // whole domain. A directory needs no such guard: mkdir answers
                // with the folder whether or not it had to make one.
                if options.contains(.mayAlreadyExist), !isDirectory,
                   let existing = try await existingFile(in: itemTemplate.parentItemIdentifier,
                                                         named: name) {
                    completionHandler(existing, pending, false, nil)
                    return
                }

                // Each of these answers with the item it produced, so nothing
                // lists the parent afterwards to find what it just made.
                let reply: DaemonResponse
                if isDirectory {
                    reply = try await client.mkdir(parentRef: parent, name: name)
                } else if itemTemplate.contentType == .symbolicLink {
                    guard let target = itemTemplate.symlinkTargetPath ?? nil else {
                        throw DaemonError.remote(code: "invalid", message: "symlink without a target")
                    }
                    reply = try await client.symlink(parentRef: parent, name: name, target: target)
                } else if let url {
                    let staged = try stage(url)
                    defer { try? FileManager.default.removeItem(at: staged) }
                    reply = try await client.write(parentRef: parent, name: name,
                                                   staging: staged.path)
                } else {
                    reply = try await client.create(parentRef: parent, name: name)
                }
                let created = reply.item.flatMap { TsyncItem.make($0, readOnly: readOnly) }
                progress.completedUnitCount = 100
                completionHandler(created, pending, false, nil)
            } catch is CancellationError {
                completionHandler(nil, [], false, CocoaError(.userCancelled))
            } catch {
                log.error("createItem \(name, privacy: .public): \(error, privacy: .public)")
                completionHandler(nil, [], false, FileProviderError.from(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        if readOnly {
            completionHandler(nil, [], false, readOnlyError())
            return progress
        }
        let task = Task {
            let ref = ItemID.wire(item.itemIdentifier)
            let pending = unsupported(changedFields)
            let moved = changedFields.contains(.filename)
                || changedFields.contains(.parentItemIdentifier)
            do {
                // Failing on a `baseVersion` mismatch needs macOS 26, above what
                // this ships against. Conflicts are settled in the daemon, which
                // publishes the losing side as a "(conflicted copy from …)"
                // file — see `File.rename`.
                _ = version

                // Whichever call ran last is the one whose reply describes the
                // item now, and each of them answers with it.
                var reply: DaemonResponse?
                if let contents = newContents, changedFields.contains(.contents) {
                    let staged = try stage(contents)
                    defer { try? FileManager.default.removeItem(at: staged) }
                    // Name and content must travel together, or the file shows
                    // up with an extension not matching its content.
                    reply = try await client.write(
                        parentRef: ItemID.wire(item.parentItemIdentifier),
                        name: item.filename, staging: staged.path)
                    if moved, ref != ItemID.wire(item.itemIdentifier) {
                        try await client.delete(ref: ref, isDirectory: false)
                    }
                } else if moved {
                    reply = try await client.rename(
                        ref: ref,
                        parentRef: ItemID.wire(item.parentItemIdentifier),
                        name: item.filename)
                }

                let updated = reply?.item.flatMap { TsyncItem.make($0, readOnly: readOnly) }
                progress.completedUnitCount = 100
                completionHandler(updated, pending, false, nil)
            } catch is CancellationError {
                completionHandler(nil, [], false, CocoaError(.userCancelled))
            } catch {
                log.error("modifyItem \(ref, privacy: .public): \(error, privacy: .public)")
                completionHandler(nil, [], false,
                                  FileProviderError.from(error, item: item.itemIdentifier))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        if readOnly {
            completionHandler(readOnlyError())
            return progress
        }
        let task = Task {
            let ref = ItemID.wire(identifier)
            let isDirectory = ItemID.folderID(of: identifier) != nil
            do {
                // The daemon's directory delete always detaches the whole
                // subtree, so a non-recursive delete is guarded here.
                if isDirectory && !options.contains(.recursive) {
                    // One entry is enough to answer "is it empty".
                    let children = try await client.listDir(ref, limit: 1)
                    if !children.items.isEmpty {
                        throw DaemonError.remote(code: "not_empty",
                                                 message: "the folder is not empty")
                    }
                }
                try await client.delete(ref: ref, isDirectory: isDirectory)
                completionHandler(nil)
            } catch let error as DaemonError where error.code == "not_found" {
                // Already gone remotely: the outcome that was wanted.
                completionHandler(nil)
            } catch is CancellationError {
                completionHandler(CocoaError(.userCancelled))
            } catch {
                log.error("deleteItem \(ref, privacy: .public): \(error, privacy: .public)")
                completionHandler(FileProviderError.from(error, item: identifier))
            }
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - Enumeration

    /// One enumerator per container contract, so neither has to ask what kind of
    /// container it is holding.
    ///
    /// A directory gets items only. A replicated extension may signal nothing
    /// but the working set, so a directory's change enumeration is never
    /// triggered and the working set is where every change is reported.
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        switch containerItemIdentifier {
        case .trashContainer:
            // supportsSyncingTrash = false, so the system should never ask; a
            // request that does arrive must not list a literal "trash" key.
            throw CocoaError(.featureUnsupported)
        case .workingSet:
            return WorkingSetEnumerator(client: client, materialized: materialized,
                                        domainName: domain.displayName, readOnly: readOnly)
        default:
            return DirectoryEnumerator(container: containerItemIdentifier,
                                       client: client, readOnly: readOnly)
        }
    }

    /// The system telling us what it now holds on disk. It fires on every change
    /// to that set, so the work is a refresh the next enumeration awaits rather
    /// than anything done here.
    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        Task { await materialized.refresh() }
        completionHandler()
    }

    // MARK: - Helpers

    private func readOnlyError() -> Error {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError,
                userInfo: [NSLocalizedDescriptionKey:
                            "'\(domain.displayName)' is read-only"])
    }

    /// The file already at `name` inside `parent`, if there is one.
    ///
    /// A file's reference composes from its container and its leaf, so this is
    /// one stat and never a listing. A directory has no composable reference —
    /// only the daemon assigns folder ids — which is why the caller asks the
    /// daemon to make one instead and takes back whatever it already had.
    private func existingFile(in parent: NSFileProviderItemIdentifier,
                              named name: String) async throws -> TsyncItem? {
        guard let child = ItemID.file(in: parent, named: name),
              let item = try? await client.stat(ItemID.wire(child.identifier))
        else { return nil }
        return TsyncItem.make(item, readOnly: readOnly)
    }

    /// Take our own copy: the system unlinks the URL it gave us once this call
    /// returns, and the daemon's upload outlives that. Same volume, so this is a
    /// clone and copies no data.
    ///
    /// It lands in this process's container, not the group container: the
    /// extension's sandbox can read that one but not write to it (EPERM). The
    /// daemon is unsandboxed and reads the file from here.
    private func stage(_ url: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.linkItem(at: url, to: destination)
        } catch {
            try FileManager.default.copyItem(at: url, to: destination)
        }
        return destination
    }
}

// MARK: - Finder actions

extension TsyncExtension: NSFileProviderCustomAction {
    func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                       onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                       completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard actionIdentifier.rawValue == "org.feverdreamtv.tsync.copyShareURL",
              let identifier = itemIdentifiers.first else {
            completionHandler(nil)
            progress.completedUnitCount = 1
            return progress
        }
        let task = Task {
            do {
                let url = try await client.share(ref: ItemID.wire(identifier))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                completionHandler(nil)
            } catch {
                log.error("copyShareURL failed: \(error, privacy: .public)")
                completionHandler(FileProviderError.from(error, item: identifier))
            }
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}
