import Foundation

/// passwords/macos §2: one row of a merged answer, naming the domain it came from.
struct Choice {
    let domain: String
    let id: String
    let title: String
    let detail: String
}

/// What a list asked of every domain gave: the rows, and the domains whose
/// vault is locked.
struct Listed {
    var choices: [Choice] = []
    var locked: [String] = []
}

/// The owner's passwords requests, one per call, each blocking its thread
/// (file-provider §4.3): callers keep them off the main queue.
enum Requests {
    /// passwords/macos §2: every configured domain; one that does not use
    /// passwords answers `invalid` and is left out.
    static func domains(_ url: URL = Tsync.configFile) -> [String] {
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return (json["domains"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    static func call(_ domain: String, _ action: String, _ args: [String: Any] = [:]) throws
        -> [String: Any]
    {
        var request = args
        request["action"] = "passwords_" + action
        request["domain"] = domain
        return try OwnerClient.call(request)
    }

    /// Every domain answering `ask`, its rows read by `rows`.
    private static func merged(
        _ ask: (String) throws -> [String: Any], _ rows: (String, [String: Any]) -> [Choice]
    ) -> Listed {
        var listed = Listed()
        for domain in domains() {
            do {
                listed.choices += rows(domain, try ask(domain))
            } catch let failure as OwnerFailure where failure.code == "locked" {
                listed.locked.append(domain)
            } catch {}
        }
        return listed
    }

    /// passwords/macos §3: the logins matching any of the origins.
    static func logins(origins: [String], codesOnly: Bool = false) -> Listed {
        var seen = Set<String>()
        return merged(
            { domain in
                var all: [[String: Any]] = []
                for origin in origins {
                    let reply = try call(domain, "list", ["site": origin])
                    all += reply["records"] as? [[String: Any]] ?? []
                }
                return ["records": all]
            },
            { domain, reply in
                (reply["records"] as? [[String: Any]] ?? []).compactMap { row in
                    guard row["kind"] as? String == "login", let id = row["id"] as? String,
                        seen.insert(domain + "/" + id).inserted
                    else { return nil }
                    if codesOnly && row["code"] as? Bool != true { return nil }
                    return Choice(
                        domain: domain, id: id, title: row["title"] as? String ?? "",
                        detail: row["username"] as? String ?? "")
                }
            })
    }

    /// passwords/macos §4: the passkeys answering the RP ID.
    static func passkeys(rpId: String, allow: [Data]) -> Listed {
        merged(
            { domain in
                var args: [String: Any] = ["origin": "https://" + rpId, "rpId": rpId]
                if !allow.isEmpty { args["allow"] = allow.map(base64URL) }
                return try call(domain, "passkey_match", args)
            },
            { domain, reply in
                (reply["passkeys"] as? [[String: Any]] ?? []).compactMap { row in
                    guard let id = row["id"] as? String else { return nil }
                    let name = row["userDisplayName"] as? String ?? ""
                    return Choice(
                        domain: domain, id: id, title: name.isEmpty ? rpId : name,
                        detail: row["userName"] as? String ?? "")
                }
            })
    }

    /// The domain a new passkey goes to: the only one using passwords, else
    /// the first that answers (README §6.1 asks for a pick on the CLI; the
    /// sheet names the domain it chose).
    static func creationDomain() -> String? {
        domains().first { domain in (try? call(domain, "list")) != nil }
    }

    static func unlock(_ domain: String, passphrase: String, secretKey: String?) throws {
        var request: [String: Any] = [
            "action": "vault_unlock", "domain": domain, "passphrase": passphrase,
        ]
        if let secretKey, !secretKey.isEmpty { request["secretKey"] = secretKey }
        _ = try OwnerClient.call(request)
    }

    /// file-provider §10.1: whether the unlock form also needs the secret key.
    static func enrolled(_ domain: String) -> Bool {
        let status = try? OwnerClient.call(["action": "vault_status", "domain": domain])
        return status?["enrolled"] as? Bool ?? false
    }
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func fromBase64URL(_ text: String) -> Data? {
    var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    return Data(base64Encoded: s)
}
