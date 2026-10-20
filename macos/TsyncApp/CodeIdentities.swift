import AuthenticationServices
import Foundation

/// passwords/macos §3.1: the one-time code entries Safari offers on a code field.
@available(macOS 15.0, *)
enum CodeIdentities {
    private static var written: [String]?
    private static let queue = DispatchQueue(label: "org.feverdreamtv.tsync.code-identities")

    /// Replaces the store's entries with the current set, off the main queue.
    static func refresh() {
        queue.async {
            ASCredentialIdentityStore.shared.getState { state in
                guard state.isEnabled else { return }
                queue.async { write(current()) }
            }
        }
    }

    private static func write(_ identities: [ASOneTimeCodeCredentialIdentity]) {
        let keys = identities.map {
            "\($0.serviceIdentifier.identifier) \($0.recordIdentifier ?? "") \($0.label)"
        }.sorted()
        guard keys != written else { return }
        ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities) { ok, _ in
            if ok { queue.async { written = keys } }
        }
    }

    private static func current() -> [ASOneTimeCodeCredentialIdentity] {
        guard
            let data = try? Data(contentsOf: Tsync.configFile),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let domains = (json["domains"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return domains.flatMap { domain -> [ASOneTimeCodeCredentialIdentity] in
            guard
                let reply = try? OwnerClient.call(["action": "passwords_list", "domain": domain]),
                let rows = reply["records"] as? [[String: Any]]
            else { return [] }
            return rows.flatMap { row -> [ASOneTimeCodeCredentialIdentity] in
                guard row["kind"] as? String == "login", row["code"] as? Bool == true,
                    let id = row["id"] as? String
                else { return [] }
                let title = row["title"] as? String ?? ""
                let username = row["username"] as? String ?? ""
                let label = username.isEmpty ? title : "\(title) — \(username)"
                let hosts = Set((row["urls"] as? [String] ?? []).compactMap { URL(string: $0)?.host })
                return hosts.sorted().map { host in
                    ASOneTimeCodeCredentialIdentity(
                        serviceIdentifier: ASCredentialServiceIdentifier(identifier: host, type: .domain),
                        label: label, recordIdentifier: domain + "/" + id)
                }
            }
        }
    }
}
