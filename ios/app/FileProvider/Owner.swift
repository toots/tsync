import FileProvider
import Foundation

/// The owner in this process (ios/core): the domain is booted on its first
/// request, and every request is a direct call on the caller's thread.
struct Owner {
    let domain: String

    init(domain: String) {
        self.domain = domain
        Core.start(bounded: true)
        Owner.becomeHost
        Notices.start()
    }

    /// ios.md §4.1: once per process, the keychain as the vault's keystore,
    /// and no key derived here.
    private static let becomeHost: Void = {
        let refusal = Core.text("ios_owner_host", Data((Tsync.appID + ".vault").utf8)) ?? "the core is not started"
        if !refusal.isEmpty { Footprint.record("keystore: \(refusal)") }
    }()

    func call(
        _ action: String, _ fields: [String: Any] = [:], cancellation: Cancellation = Cancellation()
    ) throws -> [String: Any] {
        try OwnerFailure.checked(answer(action, fields, cancellation: cancellation))
    }

    /// The reply as the core gave it, a refusal included: what the service
    /// hands back (ios.md §5.4).
    func answer(
        _ action: String, _ fields: [String: Any], cancellation: Cancellation = Cancellation()
    ) throws -> [String: Any] {
        if cancellation.isCancelled { throw OwnerFailure.cancelled }
        try boot()
        // ios.md §5.1: what the pass brings is announced by its notices.
        if action == "changes_since" {
            let started = Date()
            let reply = Core.text("request", domain: domain, #"{"action":"refresh"}"#)
            Footprint.record(logLabel("refresh", [:], since: started) + passSummary(reply))
        }
        var request = fields
        request["action"] = action
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let started = Date()
        let text = Core.text("request", domain: domain, line)
        let label = logLabel(action, fields, since: started)
        guard let text else {
            throw OwnerFailure.transport("the core is not started")
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
            let reply = object as? [String: Any]
        else {
            Footprint.record(label + " (no JSON reply)")
            throw OwnerFailure.transport("the core's reply is not a JSON object")
        }
        let failed = reply["ok"] as? Bool == false
        Footprint.record(
            failed ? "\(label) failed: \(reply["code"] ?? "?") \(reply["error"] ?? "")" : label + rows(reply))
        return reply
    }

    /// ios.md §7: the domain, the action, the item it names and how long it took.
    private func logLabel(_ action: String, _ fields: [String: Any], since started: Date) -> String {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let ref = (fields["ref"] as? String).map { " \($0)" } ?? ""
        return "\(domain) \(action)\(ref) \(ms) ms"
    }

    /// ios.md §7: what the refresh's pass did, when it ended in time.
    private func passSummary(_ reply: String?) -> String {
        guard
            let reply, let object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)),
            let pass = (object as? [String: Any])?["pass"] as? [String: Any]
        else { return "" }
        let fields = ["held", "covered", "merged", "entries", "end", "error"].compactMap { key in
            pass[key].map { "\(key) \($0)" }
        }
        return ": pass " + fields.joined(separator: ", ")
    }

    private func rows(_ reply: [String: Any]) -> String {
        guard let list = (reply["items"] ?? reply["ops"]) as? [Any] else { return "" }
        let more = reply["next"] != nil || reply["more"] as? Bool == true
        return ": \(list.count) rows" + (more ? ", more" : "")
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
        if Notices.firstBoot(domain) {
            Notices.signal(domain)
            Pushes.booted(domain)
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
