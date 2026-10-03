import Foundation

/// §7: an ordered page of feed ops as an unordered set of updated items and
/// deleted references. Identifiers are stable, so an item's fate is its last op.
struct ChangeBatch: Equatable {
    var updated: [Row] = []
    var deleted: [String] = []

    init(ops: [[String: Any]]) {
        var last: [String: Int] = [:]
        for (i, op) in ops.enumerated() {
            if let ref = op["ref"] as? String { last[ref] = i }
        }
        for (i, op) in ops.enumerated() {
            guard let ref = op["ref"] as? String, last[ref] == i else { continue }
            switch op["op"] as? String {
            case "delete", "rmdir":
                deleted.append(ref)
            default:
                // An op without an item updates nothing: no field is invented.
                if let item = op["item"] as? [String: Any], let row = Row(item) {
                    updated.append(row)
                }
            }
        }
    }
}
