import Foundation

/// Why a request to the owner failed (failure-model §7.2).
/// Built once and only read afterwards, so it crosses threads safely.
enum OwnerFailure: Error, @unchecked Sendable {
    /// The owner's coded refusal; `item` is the occupant an `exists` names.
    case refused(code: String, message: String, item: [String: Any]?)
    /// Nothing accepted the connection: the owner is restarting or not started.
    /// Reported as `unreachable`, which the relay unlatches when the owner
    /// answers again (file-provider §6.10).
    case noOwner(String)
    /// No answer from a connected owner: a broken connection or the client's
    /// own deadline. Treated as `internal`, never `unreachable` or `not_found`.
    case transport(String)
    case cancelled

    /// The code a client acts on: a missing or unknown one reads as `internal`.
    var code: String {
        switch self {
        case .refused(let code, _, _):
            return OwnerFailure.knownCodes.contains(code) ? code : "internal"
        case .noOwner: return "unreachable"
        case .transport: return "internal"
        case .cancelled: return "cancelled"
        }
    }

    var message: String {
        switch self {
        case .refused(_, let message, _): return message
        case .noOwner(let why), .transport(let why): return why
        case .cancelled: return "cancelled"
        }
    }

    static let knownCodes: Set<String> = [
        "not_found", "exists", "not_empty", "read_only", "denied", "invalid", "unreachable",
        "busy", "paused", "locked", "internal",
    ]

    /// The reply itself when it is `ok`, else its refusal.
    static func checked(_ reply: [String: Any]) throws -> [String: Any] {
        if reply["ok"] as? Bool == true { return reply }
        throw OwnerFailure.refused(
            code: reply["code"] as? String ?? "internal",
            message: reply["error"] as? String ?? "the owner refused the request",
            item: reply["item"] as? [String: Any])
    }
}
