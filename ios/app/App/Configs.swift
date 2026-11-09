import FileProvider
import Foundation

/// The config file, as android-app §6.1 keeps it: only a text every new
/// domain's check accepts is written, and each domain is registered with
/// the File Provider under its display name.
enum Configs {
    static func server(name: String, url: String, secret: String) -> [String: Any] {
        domain(name, backend: [
            "type": "http-proxy", "name": "server", "role": "main",
            "url": url.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), "secret": secret,
        ])
    }

    /// A domain whose store is in the container, to try the extension
    /// without a server.
    static func localTest() -> [String: Any] {
        domain("Test", backend: [
            "type": "local", "name": "main", "role": "main",
            "path": Core.group.appendingPathComponent("test-store").path,
        ])
    }

    private static func domain(_ name: String, backend: [String: Any]) -> [String: Any] {
        [
            "name": name, "versioning": true, "maxCache": "2G", "symlinks": "skip",
            "frontends": ["android"], "backends": [backend],
        ]
    }

    /// The core's refusal of the first new domain it refuses, else nil.
    static func add(_ added: [[String: Any]]) -> String? {
        let current = read()
        let kept = current["domains"] as? [[String: Any]] ?? []
        let names = Set(kept.compactMap { $0["name"] as? String })
        let fresh = added.filter { !names.contains($0["name"] as? String ?? "") }
        if fresh.isEmpty { return "already joined" }
        let config: [String: Any] = [
            "name": current["name"] as? String ?? "iphone", "domains": kept + fresh,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config),
            let candidate = String(data: data, encoding: .utf8)
        else { return "the config does not encode" }
        for domain in fresh {
            let name = domain["name"] as? String ?? ""
            if let sentence = Core.checkConfig(name, candidate: candidate) {
                return "\(name): \(sentence)"
            }
        }
        do {
            let file = Core.configFile
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    private static func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: Core.configFile),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    static func registerAll() {
        for name in Tsync.domainNames(Core.configFile) {
            let domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(domainIdentifier(name)), displayName: name)
            NSFileProviderManager.add(domain) { error in
                if let error = error { NSLog("tsync: registering \(name): \(error)") }
            }
        }
    }
}
