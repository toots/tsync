import Foundation
import os

private let trace = Logger(subsystem: "org.feverdreamtv.tsync.credentials", category: "requests")

/// passwords/macos §2: one row of a merged answer, naming the domain it came from.
struct Choice {
    let domain: String
    let id: String
    let title: String
    let detail: String
    /// passwords/macos §4: a passkey row of a sheet that also lists logins.
    var passkey = false
}

/// What a list asked of every domain gave: the rows, the domains whose vault is
/// locked, and those that did not answer (§2: never reported as empty).
struct Listed {
    var choices: [Choice] = []
    var locked: [String] = []
    var unanswered: [String] = []

    mutating func merge(_ other: Listed) {
        choices += other.choices
        locked += other.locked.filter { !locked.contains($0) }
        unanswered += other.unanswered.filter { !unanswered.contains($0) }
    }
}

/// §4: where a new passkey goes.
enum CreationDomain {
    case domain(String)
    case locked(String)
    /// Several domains use passwords and none of them is the default.
    case several([String])
    case none
}

/// The owner's passwords requests, one per call, each blocking its thread
/// (file-provider §4.3): callers keep them off the main queue.
enum Requests {
    static func call(_ domain: String, _ action: String, _ args: [String: Any] = [:]) throws
        -> [String: Any]
    {
        var request = args
        request["action"] = "passwords_" + action
        request["domain"] = domain
        return try OwnerClient.call(request)
    }

    /// Every domain answering `ask`, its rows read by `rows`. A domain that
    /// does not use passwords refuses `invalid` and is left out.
    private static func merged(
        _ ask: (String) throws -> [String: Any], _ rows: (String, [String: Any]) -> [Choice]
    ) -> Listed {
        var listed = Listed()
        for domain in Tsync.domainNames() {
            do {
                listed.choices += rows(domain, try ask(domain))
            } catch let failure as OwnerFailure where failure.code == "locked" {
                listed.locked.append(domain)
            } catch let failure as OwnerFailure where failure.code == "invalid" {
                trace.info("\(domain, privacy: .public) refused: invalid")
            } catch {
                trace.info("\(domain, privacy: .public) did not answer")
                listed.unanswered.append(domain)
            }
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
        trace.info("passkeys of \(rpId, privacy: .public), \(allow.count) allowed")
        return merged(
            { domain in
                var args: [String: Any] = ["origin": "https://" + rpId, "rpId": rpId]
                if !allow.isEmpty { args["allow"] = allow.map(\.base64URL) }
                return try call(domain, "passkey_match", args)
            },
            { domain, reply in
                (reply["passkeys"] as? [[String: Any]] ?? []).compactMap { row in
                    guard let id = row["id"] as? String else { return nil }
                    let name = row["userDisplayName"] as? String ?? ""
                    return Choice(
                        domain: domain, id: id, title: name.isEmpty ? rpId : name,
                        detail: row["userName"] as? String ?? "", passkey: true)
                }
            })
    }

    /// extensions README §6.1: the only domain using passwords, else the default domain
    /// when it does; a locked one is named so the sheet can say so.
    static func creationDomain() -> CreationDomain {
        var using: [(name: String, locked: Bool)] = []
        for domain in Tsync.domainNames() {
            do {
                _ = try call(domain, "list", ["use": false])
                using.append((domain, false))
            } catch let failure as OwnerFailure where failure.code == "locked" {
                using.append((domain, true))
            } catch {}
        }
        let preferred = (try? String(contentsOf: Tsync.dataDir.appendingPathComponent("default-domain"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = using.count == 1 ? using.first : using.first(where: { $0.name == preferred }) else {
            return using.isEmpty ? .none : .several(using.map(\.name))
        }
        return target.locked ? .locked(target.name) : .domain(target.name)
    }

    /// A binary member of a reply; a reply without it is malformed.
    static func data(_ reply: [String: Any], _ key: String) throws -> Data {
        guard let text = reply[key] as? String, let data = Data(base64URL: text), !data.isEmpty else {
            throw OwnerFailure.refused(code: "internal", message: "the reply has no \(key)", item: nil)
        }
        return data
    }
}
