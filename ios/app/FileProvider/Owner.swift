import FileProvider
import Foundation

/// The owner in this process (ios/core): the domain is booted on its first
/// request, and every request is a direct call on the caller's thread.
struct Owner {
    let domain: String

    init(domain: String) {
        self.domain = domain
        Core.start(bounded: true)
        Notices.start()
    }

    func call(
        _ action: String, _ fields: [String: Any] = [:], cancellation: Cancellation = Cancellation()
    ) throws -> [String: Any] {
        if cancellation.isCancelled { throw OwnerFailure.cancelled }
        try boot()
        // ios.md §5.1: what the pass brings is announced by its notices.
        if action == "changes_since" { _ = Core.text("request", domain: domain, #"{"action":"refresh"}"#) }
        var request = fields
        request["action"] = action
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        guard let text = Core.text("request", domain: domain, line) else {
            throw OwnerFailure.transport("the core is not started")
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
            let reply = object as? [String: Any]
        else {
            Footprint.record(action + " (no JSON reply)")
            throw OwnerFailure.transport("the core's reply is not a JSON object")
        }
        let failed = reply["ok"] as? Bool == false
        Footprint.record(failed ? "\(action) failed: \(reply["code"] ?? "?") \(reply["error"] ?? "")" : action)
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

    /// Idempotent per domain in the core; a failure answers `internal`. The
    /// first boot in a process signals the working set (ios.md §5.1).
    private func boot() throws {
        let sentence = Core.text("boot", Data(domain.utf8)) ?? "the core is not started"
        if !sentence.isEmpty {
            throw OwnerFailure.refused(code: "internal", message: sentence, item: nil)
        }
        if Notices.firstBoot(domain) { Notices.signal(domain) }
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
