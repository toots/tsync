import FileProvider
import Foundation

/// The owner in this process (ios/core): the domain is booted on its first
/// request, and every request is a direct call on the caller's thread.
struct Owner {
    let domain: String

    init(domain: String) {
        self.domain = domain
        Core.start(bounded: true)
        Footprint.startSampling()
    }

    func call(
        _ action: String, _ fields: [String: Any] = [:], cancellation: Cancellation = Cancellation()
    ) throws -> [String: Any] {
        if cancellation.isCancelled { throw OwnerFailure.cancelled }
        try boot()
        var request = fields
        request["action"] = action
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        guard let text = Core.text("request", domain: domain, line) else {
            throw OwnerFailure.transport("the core is not started")
        }
        Footprint.record(action)
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
            let reply = object as? [String: Any]
        else { throw OwnerFailure.transport("the core's reply is not a JSON object") }
        return try OwnerFailure.checked(reply)
    }

    /// A direct call has no connection to watch, so a bulk request is an
    /// ordinary one. A write answers once its upload is done (android §5
    /// `await`): with no working-set feed, the system learns an item is
    /// uploaded only from the reply of the callback that wrote it.
    func bulk(
        _ action: String, _ fields: [String: Any], cancellation: Cancellation
    ) throws -> [String: Any] {
        var fields = fields
        if action == "write" { fields["await"] = true }
        return try call(action, fields, cancellation: cancellation)
    }

    /// Idempotent per domain in the core; a failure answers `internal`.
    private func boot() throws {
        let sentence = Core.text("boot", Data(domain.utf8)) ?? "the core is not started"
        if !sentence.isEmpty {
            throw OwnerFailure.refused(code: "internal", message: sentence, item: nil)
        }
    }
}

/// A request is a call into the core that cannot be interrupted: a
/// cancellation stops what has not started and completes the callback at once.
final class Cancellation {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

// ponytail: the lazy tree has no change feed yet (ios.md §9 item 1), so the
// working set is empty and remote changes appear when a folder is listed again.
func workingSetEnumerator(_ owner: Owner) -> NSFileProviderEnumerator {
    EmptyWorkingSet()
}

final class EmptyWorkingSet: NSObject, NSFileProviderEnumerator {
    private static let anchor = NSFileProviderSyncAnchor(Data("0".utf8))

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
    ) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
    ) {
        observer.finishEnumeratingChanges(upTo: Self.anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchor)
    }
}
