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

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let config = (try? Config.load()) ?? Config(domains: [])
        self.readOnly = config.isReadOnly(domain.displayName)
        self.client = DaemonClient(domain: domain.displayName)
        super.init()
        log.info("init: \(domain.identifier.rawValue, privacy: .public)")
    }

    /// Nothing to tear down. This process holds no channel of its own: the daemon
    /// is reached by connecting out, and being told about changes is the app's
    /// job, because the app is still running when this is not.
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

    /// This is the system's authority on whether an item still exists: answering
    /// for one that is gone keeps it on disk forever. Directories used to be
    /// answered for straight from the identifier without asking anyone, which is
    /// how a deleted folder could outlive its own deletion indefinitely.
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
            // Poll the daemon while the fetch is in flight. Asked before the
            // first sleep, so the bar becomes a real one as soon as the daemon
            // knows the size rather than half a second later.
            //
            // An answer of "nothing running" leaves the bar where it is instead
            // of skipping the update: it means the work has not started yet or
            // has just finished, and either way winding back to indeterminate
            // would look like the transfer had restarted.
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
                // The system takes ownership of the file, and this process is not
                // allowed to move one into that directory itself — it fails with
                // EPERM, on locally signed and notarised builds alike. So the
                // daemon is asked to assemble it there to begin with.
                guard let manager = NSFileProviderManager(for: domain),
                      let temporary = try? manager.temporaryDirectoryURL() else {
                    throw DaemonError.transport("no temporary directory for domain")
                }
                let destination = temporary.appendingPathComponent(UUID().uuidString)
                try await client.ensureCached(ref: ref, destination: destination.path)
                try Task.checkCancellation()
                // Finish the bar explicitly. The last poll lands somewhere short
                // of the end, and a bar that simply disappears at 90% reads as an
                // abandoned transfer rather than a completed one.
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
        // The system cancels a fetch that is taking too long and then expects the
        // completion handler promptly. Without this it waits on a request nobody
        // is going to answer.
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    /// Serve one range instead of the whole file.
    ///
    /// This is what makes a large file usable rather than merely legible: opening
    /// a 5 GB movie reads its header, and answering that read with the header is
    /// the difference between playing at once and waiting for the whole download.
    /// The system asks for the range an application actually touched, writes the
    /// piece we hand back into its own copy at that offset, and comes back for
    /// more as the application reads on.
    ///
    /// Whole-file `fetchContents` stays: the system still uses it to materialize
    /// a file outright, and this method is only ever an optimisation on top.
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
                // With strict versioning the system discards anything but the
                // version it asked for, so answering with the version we have
                // would waste the transfer. Saying so instead lets it re-ask for
                // the version we do have.
                if options.contains(.strictVersioning),
                   item.itemVersion.contentVersion != requestedVersion.contentVersion {
                    throw NSError(domain: NSFileProviderErrorDomain,
                                  code: NSFileProviderError.versionNoLongerAvailable.rawValue)
                }

                let range = PartialRange.aligned(covering: requestedRange,
                                                 alignment: alignment,
                                                 documentSize: item.documentSize?.int64Value ?? 0)
                // Same constraint as the whole-file path: the system takes
                // ownership of this file and this process may not move one into
                // its directory, so the daemon writes it there to begin with.
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

    /// Fields this side cannot store. Handing them back as still pending stops
    /// the system propagating its own idea of them to disk — which is what
    /// silently reverted a user's Finder tags — and, once a call reports the same
    /// set it was given, stops it offering them again.
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
                // A reimport replays everything already on disk through this call.
                // Matching an existing item instead of creating a second one is
                // what keeps that from re-uploading the whole domain.
                let isDirectory = itemTemplate.contentType == .folder
                if options.contains(.mayAlreadyExist),
                   let existing = try await lookup(parent: itemTemplate.parentItemIdentifier,
                                                   name: name, isDirectory: isDirectory) {
                    completionHandler(existing, pending, false, nil)
                    return
                }

                let created: TsyncItem?
                if isDirectory {
                    _ = try await client.mkdir(parentRef: parent, name: name)
                    created = try await lookup(parent: itemTemplate.parentItemIdentifier,
                                               name: name, isDirectory: true)
                } else if itemTemplate.contentType == .symbolicLink {
                    guard let target = itemTemplate.symlinkTargetPath ?? nil else {
                        throw DaemonError.remote(code: "invalid", message: "symlink without a target")
                    }
                    _ = try await client.symlink(parentRef: parent, name: name, target: target)
                    created = try await lookup(parent: itemTemplate.parentItemIdentifier,
                                               name: name, isDirectory: false)
                } else if let url {
                    let staged = try stage(url)
                    defer { try? FileManager.default.removeItem(at: staged) }
                    _ = try await client.write(parentRef: parent, name: name, staging: staged.path)
                    created = try await lookup(parent: itemTemplate.parentItemIdentifier,
                                               name: name, isDirectory: false)
                } else {
                    _ = try await client.create(parentRef: parent, name: name)
                    created = try await lookup(parent: itemTemplate.parentItemIdentifier,
                                               name: name, isDirectory: false)
                }
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
                // `baseVersion` says which state the system was editing from, and
                // the option that asks us to fail on a mismatch needs macOS 26,
                // above what this ships against. Conflicts are settled in the
                // daemon instead, which publishes the losing side alongside as a
                // "(conflicted copy from …)" file rather than choosing for the
                // user — see `File.rename`.
                _ = version

                if let contents = newContents, changedFields.contains(.contents) {
                    let staged = try stage(contents)
                    defer { try? FileManager.default.removeItem(at: staged) }
                    // Name and content travel together: written apart, a file
                    // shows up elsewhere with an extension that does not match
                    // what is in it.
                    _ = try await client.write(
                        parentRef: ItemID.wire(item.parentItemIdentifier),
                        name: item.filename, staging: staged.path)
                    if moved, ref != ItemID.wire(item.itemIdentifier) {
                        try await client.delete(ref: ref, isDirectory: false)
                    }
                } else if moved {
                    _ = try await client.rename(
                        ref: ref,
                        parentRef: ItemID.wire(item.parentItemIdentifier),
                        name: item.filename)
                }

                let updated = try await lookup(parent: item.parentItemIdentifier,
                                               name: item.filename,
                                               isDirectory: ItemID.folderID(of: item.itemIdentifier) != nil)
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
                // The daemon's directory delete detaches the whole subtree at
                // once. That is right for a recursive delete and wrong for a
                // plain one, which must refuse a directory with anything in it —
                // so the check lives here, where the distinction is made.
                if isDirectory && !options.contains(.recursive) {
                    let children = try await client.listDir(ref)
                    if !children.isEmpty {
                        throw DaemonError.remote(code: "not_empty",
                                                 message: "the folder is not empty")
                    }
                }
                try await client.delete(ref: ref, isDirectory: isDirectory)
                completionHandler(nil)
            } catch let error as DaemonError where error.code == "not_found" {
                // Already gone remotely, which is the outcome that was wanted.
                completionHandler(nil)
            } catch is CancellationError {
                completionHandler(CocoaError(.userCancelled))
            } catch {
                completionHandler(FileProviderError.from(error, item: identifier))
            }
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        // The domain is registered with supportsSyncingTrash = false, so the
        // system should never ask — but a request that does arrive has a defined
        // answer, and it is not a listing of whatever a literal "trash" key finds.
        if containerItemIdentifier == .trashContainer {
            throw CocoaError(.featureUnsupported)
        }
        return TsyncEnumerator(container: containerItemIdentifier, client: client,
                               domainName: domain.displayName, readOnly: readOnly)
    }

    // MARK: - Helpers

    private func readOnlyError() -> Error {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError,
                userInfo: [NSLocalizedDescriptionKey:
                            "'\(domain.displayName)' is read-only"])
    }

    /// The item now at `name` inside `parent`.
    ///
    /// A file's reference is composable from its container and its leaf, which
    /// saves listing the whole folder. A directory's is not — only the daemon
    /// assigns a folder id — so it is found by listing. Asking for a directory by
    /// the composed file form would name the same thing by the wrong kind of
    /// reference, and the caller would then build its children's names from it.
    private func lookup(parent: NSFileProviderItemIdentifier, name: String,
                        isDirectory: Bool) async throws -> TsyncItem? {
        if !isDirectory, let child = ItemID.file(in: parent, named: name),
           let item = try? await client.stat(ItemID.wire(child.identifier)) {
            return TsyncItem.make(item, readOnly: readOnly)
        }
        let siblings = try await client.listDir(ItemID.wire(parent))
        guard let match = siblings.first(where: { $0.name == name }) else { return nil }
        return TsyncItem.make(match, readOnly: readOnly)
    }

    /// Hand the system's file over as a copy of our own. The system unlinks the
    /// URL it gave us once this call returns, and the daemon's upload outlives
    /// that. Same volume, so this is a clone and copies no data.
    ///
    /// It goes in this process's own container, not the group container the
    /// daemon lives in. The extension's sandbox lets it read the group container
    /// but not write to it — creating anything there fails with EPERM, which is
    /// almost certainly why an earlier design's socket, which this process was
    /// supposed to bind in that same directory, was never there. The app has no
    /// such limit, and the daemon is unsandboxed, so it can read the file from
    /// here and rename it away.
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
