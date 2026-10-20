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
                queue.async {
                    // The system empties the store while AutoFill is off.
                    guard state.isEnabled else { return written = nil }
                    write(current())
                }
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
        Tsync.domainNames().flatMap { domain -> [ASCredentialIdentity] in
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
                let credentialID = Data(base64URL: row["credentialId"] as? String ?? ""),
                let userHandle = Data(base64URL: row["userHandle"] as? String ?? "")
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
            let services = Dictionary(
                (row["urls"] as? [String] ?? []).compactMap(service).map { ($0.identifier, $0) },
                uniquingKeysWith: { first, _ in first })
            return services.keys.sorted().map {
                ASOneTimeCodeCredentialIdentity(
                    serviceIdentifier: services[$0]!, label: label, recordIdentifier: record)
            }
        default:
            return []
        }
    }

    /// §3.1: a web site's service, its host alone or with its port as a URL;
    /// an `android://` site has none.
    private static func service(_ site: String) -> ASCredentialServiceIdentifier? {
        guard let url = URL(string: site), let host = url.host,
            url.scheme == "https" || url.scheme == "http"
        else { return nil }
        return url.port == nil
            ? ASCredentialServiceIdentifier(identifier: host, type: .domain)
            : ASCredentialServiceIdentifier(identifier: site, type: .URL)
    }
}
