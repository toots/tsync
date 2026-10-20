import AuthenticationServices
import Foundation

/// passwords/macos §3.1, §4.1: the entries Safari names in its suggestions.
@available(macOS 14.0, *)
enum Identities {
    private static var written: [String]?
    private static let queue = DispatchQueue(label: "org.feverdreamtv.tsync.identities")

    /// Replaces the store's entries with the current set, off the main queue.
    static func refresh() {
        queue.async {
            ASCredentialIdentityStore.shared.getState { state in
                guard state.isEnabled else { return }
                queue.async { write(current()) }
            }
        }
    }

    private static func write(_ identities: [ASCredentialIdentity]) {
        let keys = identities.map {
            "\($0.serviceIdentifier.identifier) \($0.recordIdentifier ?? "") \($0.user)"
        }.sorted()
        guard keys != written else { return }
        ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities) { ok, _ in
            if ok { queue.async { written = keys } }
        }
    }

    private static func current() -> [ASCredentialIdentity] {
        guard
            let data = try? Data(contentsOf: Tsync.configFile),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let domains = (json["domains"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return domains.flatMap { domain -> [ASCredentialIdentity] in
            guard
                let reply = try? OwnerClient.call(["action": "passwords_list", "domain": domain]),
                let rows = reply["records"] as? [[String: Any]]
            else { return [] }
            return rows.flatMap { row in entries(row, record: domain + "/" + (row["id"] as? String ?? "")) }
        }
    }

    private static func entries(_ row: [String: Any], record: String) -> [ASCredentialIdentity] {
        switch row["kind"] as? String {
        case "passkey":
            guard let rpId = row["rpId"] as? String,
                let credentialID = fromBase64URL(row["credentialId"] as? String ?? ""),
                let userHandle = fromBase64URL(row["userHandle"] as? String ?? "")
            else { return [] }
            return [
                ASPasskeyCredentialIdentity(
                    relyingPartyIdentifier: rpId, userName: row["userName"] as? String ?? "",
                    credentialID: credentialID, userHandle: userHandle, recordIdentifier: record)
            ]
        case "login":
            guard #available(macOS 15.0, *), row["code"] as? Bool == true else { return [] }
            let title = row["title"] as? String ?? ""
            let username = row["username"] as? String ?? ""
            let label = username.isEmpty ? title : "\(title) — \(username)"
            let hosts = Set((row["urls"] as? [String] ?? []).compactMap { URL(string: $0)?.host })
            return hosts.sorted().map { host in
                ASOneTimeCodeCredentialIdentity(
                    serviceIdentifier: ASCredentialServiceIdentifier(identifier: host, type: .domain),
                    label: label, recordIdentifier: record)
            }
        default:
            return []
        }
    }

    private static func fromBase64URL(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}
