import AuthenticationServices
import Foundation
import Security
import UIKit

/// ios-app.md §6: the vault domains, their state, and what the Vault screen asks
/// of their owners through the service. Every request is made off the main thread.
@MainActor
final class VaultModel: ObservableObject {
    enum State: Equatable {
        case asking
        case unreachable(String)
        case turnedOff
        case noVault
        case corrupt(String)
        case locked(enrolled: Bool, lockedBy: String?)
        case unlocked
    }

    struct Domain: Identifiable, Equatable {
        let name: String
        var state = State.asking
        var look: UIImage?
        var status: String = ""
        var id: String { name }
    }

    @Published private(set) var domains: [Domain] = []

    /// After launch and on each return to the foreground.
    func refresh() {
        let configured = Tsync.domainNames()
        Task {
            var kept = Set(Tsync.vaultDomainNames())
            var asked: [Domain] = []
            for name in configured {
                let answer = await Self.status(name)
                // A domain that does not answer keeps its place.
                switch answer.domain.state {
                case .unreachable, .turnedOff: break
                default: if answer.usesNoExtension { kept.remove(name) } else { kept.insert(name) }
                }
                if kept.contains(name) { asked.append(answer.domain) }
            }
            UserDefaults(suiteName: Tsync.appGroup)?.set(configured.filter(kept.contains), forKey: Tsync.vaultDomainsKey)
            domains = asked
            Self.refreshIdentities()
        }
    }

    private static func status(_ name: String) async -> (domain: Domain, usesNoExtension: Bool) {
        var domain = Domain(name: name)
        do {
            let reply = try await ask(name, "vault_status")
            domain.look = (reply["appearance"] as? [String: Any]).flatMap(VaultLook.image)
            let enrolled = reply["enrolled"] as? Bool == true
            switch reply["vault"] as? String {
            case "absent": domain.state = .noVault
            case "unlocked": domain.state = .unlocked
            case "locked": domain.state = .locked(enrolled: enrolled, lockedBy: reply["lockedBy"] as? String)
            default: domain.state = .corrupt(reply["corrupt"] as? String ?? "the keyring is unreadable")
            }
            domain.status = [
                domain.state == .unlocked ? "Unlocked" : "Locked",
                enrolled ? "this iPhone is enrolled" : "this iPhone is not enrolled",
                (reply["cached"] as? String).map { "key kept in \($0 == "keystore" ? "the keychain" : "memory")" },
            ].compactMap { $0 }.joined(separator: ", ")
            return (domain, false)
        } catch OwnerFailure.turnedOff {
            domain.state = .turnedOff
        } catch let failure as OwnerFailure where failure.code == "invalid" {
            return (domain, true)
        } catch let failure as OwnerFailure where failure.code == "not_found" {
            domain.state = .noVault
        } catch {
            domain.state = .unreachable((error as? OwnerFailure)?.message ?? error.localizedDescription)
        }
        return (domain, false)
    }

    func reload(_ name: String) {
        Task {
            let answer = await Self.status(name)
            if let i = domains.firstIndex(where: { $0.name == name }) { domains[i] = answer.domain }
            Self.refreshIdentities()
        }
    }

    // MARK: unlocking (vault §6.4)

    /// Nil on success, else the owner's sentence to show on the fields.
    func unlock(_ name: String, passphrase: String, secretKey typed: String?) async -> String? {
        defer { reload(name) }
        do {
            try await Self.unlock(name, passphrase: passphrase, typed: typed, again: true)
            return nil
        } catch {
            return (error as? OwnerFailure)?.message ?? error.localizedDescription
        }
    }

    private static func unlock(_ name: String, passphrase: String, typed: String?, again: Bool) async throws {
        let slots = try await ask(name, "vault_slots")
        let enrolled = slots["enrolled"] as? String
        // The field's, else the keychain's when this iPhone is enrolled.
        guard let secretKey = typed ?? enrolled.flatMap({ SecretKeyEntry.read(domain: name, id: $0) }) else {
            throw OwnerFailure.refused(code: "invalid", message: "this iPhone needs the vault's secret key", item: nil)
        }
        let keks = try await Task.detached { try derive(slots, passphrase: passphrase, secretKey: secretKey) }.value
        var fields: [String: Any] = ["keks": keks]
        if typed != nil { fields["secretKey"] = secretKey }
        do {
            _ = try await ask(name, "vault_unlock", fields)
        } catch let failure as OwnerFailure where again && failure.message.hasPrefix("the keyring changed") {
            try await unlock(name, passphrase: passphrase, typed: typed, again: false)
        }
    }

    /// The core's pure call, in this process: Argon2id needs more memory than
    /// the extension has.
    nonisolated private static func derive(_ slots: [String: Any], passphrase: String, secretKey: String) throws
        -> [String: Any]
    {
        var request = slots
        request["passphrase"] = passphrase
        request["secretKey"] = secretKey
        let json = try JSONSerialization.data(withJSONObject: request)
        guard let text = Core.text("vault_derive", json),
            let reply = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        else { throw OwnerFailure.transport("the core did not derive") }
        if let error = reply["error"] as? String {
            throw OwnerFailure.refused(code: "denied", message: error, item: nil)
        }
        guard let keks = reply["keks"] as? [String: Any] else { throw OwnerFailure.transport("no keys derived") }
        return keks
    }

    func lock(_ name: String, forget: Bool) async -> String? {
        defer { reload(name) }
        do {
            _ = try await Self.ask(name, "vault_lock", forget ? ["forget": true] : [:])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// vault §6.2: while the app runs, a screen lock reaches every vault domain.
    func screenLocked() {
        let names = domains.map(\.name)
        Task.detached { for name in names { _ = try? await Self.ask(name, "vault_lock", ["reason": "screen"]) } }
    }

    // MARK: requests

    nonisolated static func ask(_ domain: String, _ action: String, _ fields: [String: Any] = [:]) async throws
        -> [String: Any]
    {
        var request = fields
        request["action"] = action
        request["domain"] = domain
        return try await Task.detached { try OwnerClient.call(request) }.value
    }

    /// passwords/ios §4.
    nonisolated static func refreshIdentities() {
        if #available(iOS 17.0, *) { Identities.refresh() }
    }
}

/// security-model §10.6: the secret key entry the extension wrote, which the
/// app reads to derive (vault §6.4). The item holds the secret key's id, then
/// its 16 bytes.
enum SecretKeyEntry {
    static func read(domain: String, id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Tsync.appID + ".vault",
            kSecAttrAccount as String: domain + "/secret-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
            let entry = found as? Data, entry.count == 32,
            String(decoding: entry.prefix(16), as: UTF8.self) == id
        else { return nil }
        return spelled(entry.suffix(16))
    }

    /// vault §2.1: Crockford base32, most significant bit first, two zero bits
    /// of padding, in groups 5-5-5-5-6.
    static func spelled(_ bytes: Data) -> String {
        let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
        let bits: [Int] = Array(bytes).flatMap { byte in (0..<8).map { Int(byte >> (7 - $0)) & 1 } } + [0, 0]
        let symbols = stride(from: 0, to: bits.count, by: 5).map { start in
            alphabet[bits[start..<start + 5].reduce(0) { $0 << 1 | $1 }]
        }
        return [0..<5, 5..<10, 10..<15, 15..<20, 20..<26].map { String(symbols[$0]) }.joined(separator: "-")
    }
}
