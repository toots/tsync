import FileProvider
import Foundation

/// The owner as one domain sees it: every request names the domain by its
/// display name (§3.3), and runs off the caller's thread so no framework
/// callback queue blocks on the socket (§4.3).
struct Owner {
    let domain: String

    func call(
        _ action: String, _ fields: [String: Any] = [:], cancellation: Cancellation = Cancellation()
    ) throws -> [String: Any] {
        var request = fields
        request["action"] = action
        request["domain"] = domain
        return try OwnerClient.call(request, cancellation: cancellation)
    }

    func bulk(
        _ action: String, _ fields: [String: Any], cancellation: Cancellation
    ) throws -> [String: Any] {
        var request = fields
        request["action"] = action
        request["domain"] = domain
        return try OwnerClient.bulk(request, cancellation: cancellation)
    }
}
