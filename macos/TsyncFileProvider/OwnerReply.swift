import Foundation

extension Owner {
    /// The reply's row: at the top level for `stat`, nested as `item` otherwise.
    /// A reply without one fails the callback as `internal` (§6.9).
    static func row(_ reply: [String: Any], nested: Bool = true) throws -> Row {
        let json = nested ? reply["item"] as? [String: Any] : reply
        guard let json = json, let row = Row(json) else {
            throw OwnerFailure.refused(
                code: "internal", message: "the owner's reply names no item", item: nil)
        }
        return row
    }
}

/// Runs blocking work on a thread of its own, never on a framework queue or a
/// shared pool other requests need.
func detached(_ body: @escaping () -> Void) {
    Thread.detachNewThread(body)
}
