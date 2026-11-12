import FileProvider
import Foundation
import UIKit

/// The config file, as android-app §6.1 keeps it: only a text every new
/// domain's check accepts is written, and each domain is registered with
/// the File Provider under its display name.
enum Configs {
    static func server(name: String, url: String, secret: String) -> [String: Any] {
        domain(name, backend: [
            "type": "http-proxy", "name": "server", "role": "main",
            "url": trimmedURL(url), "secret": secret,
        ])
    }

    /// android-app §6.1: surrounding blanks, then trailing slashes.
    private static func trimmedURL(_ url: String) -> String {
        var url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// A domain whose store is in the container, to try the extension
    /// without a server.
    static func localTest() -> [String: Any] {
        domain("Test", backend: [
            "type": "local", "name": "main", "role": "main",
            "path": Tsync.groupContainer.appendingPathComponent("test-store").path,
        ])
    }

    /// The test server the build was given (run-device.sh), if any.
    static func testServer() -> [String: Any]? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let url = info["TsyncTestServerURL"] as? String, !url.isEmpty,
            let secret = info["TsyncTestServerSecret"] as? String, !secret.isEmpty
        else { return nil }
        return server(name: "Phone Test", url: url, secret: secret)
    }

    private static func domain(_ name: String, backend: [String: Any]) -> [String: Any] {
        // No `symlinks`: the domain takes its main's policy (android.md §3.4).
        [
            "name": name, "versioning": true, "maxCache": "2G",
            "frontends": ["android"], "backends": [backend],
        ]
    }

    /// The core's refusal of the first new domain it refuses, else nil.
    static func add(_ added: [[String: Any]]) -> String? {
        let current = read()
        let kept = current["domains"] as? [[String: Any]] ?? []
        let names = Set(kept.compactMap { $0["name"] as? String })
        let fresh = added.filter { !names.contains($0["name"] as? String ?? "") }
        if fresh.isEmpty { return nil }
        let config: [String: Any] = [
            "name": current["name"] as? String ?? deviceName(), "domains": kept + fresh,
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
        return write(data)
    }

    /// android-app §6.1: atomically, owner-only.
    private static func write(_ data: Data) -> String? {
        do {
            let file = Tsync.configFile
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

    /// A configured domain, as Settings lists it.
    struct Entry: Identifiable {
        let name: String
        let server: String
        var id: String { name }
    }

    static func entries() -> [Entry] {
        (read()["domains"] as? [[String: Any]] ?? []).compactMap { domain in
            guard let name = domain["name"] as? String else { return nil }
            let backend = (domain["backends"] as? [[String: Any]])?.first ?? [:]
            let server = backend["url"] as? String ?? backend["path"] as? String ?? ""
            return Entry(name: name, server: server)
        }
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: Tsync.configFile.path) }

    /// The core's sentence when the config does not load, else nil.
    static func loadFailure() -> String? {
        guard let first = entries().first else { return "the config names no domain" }
        guard let text = try? String(contentsOf: Tsync.configFile, encoding: .utf8) else {
            return "the config cannot be read"
        }
        return Core.checkConfig(first.name, candidate: text)
    }

    /// Takes the domain out of the config, keeping its entry for `waitsForRestart`.
    static func remove(_ name: String) -> String? {
        var current = read()
        let domains = current["domains"] as? [[String: Any]] ?? []
        guard let removed = domains.first(where: { $0["name"] as? String == name }) else { return nil }
        current["domains"] = domains.filter { $0["name"] as? String != name }
        guard let data = try? JSONSerialization.data(withJSONObject: current) else {
            return "the config does not encode"
        }
        if let refusal = write(data) { return refusal }
        UserDefaults.standard.set(
            try? JSONSerialization.data(withJSONObject: removed), forKey: keptKey(name))
        return nil
    }

    /// ios-app.md §5: the joined domains whose settings differ from those they
    /// were removed with, which a booted extension may still serve. Their
    /// kept entries go.
    static func waitsForRestart(_ joined: [[String: Any]]) -> [String] {
        joined.compactMap { domain in
            guard let name = domain["name"] as? String else { return nil }
            let key = keptKey(name)
            defer { UserDefaults.standard.removeObject(forKey: key) }
            guard let data = UserDefaults.standard.data(forKey: key),
                let kept = try? JSONSerialization.jsonObject(with: data) as? NSDictionary
            else { return nil }
            return kept.isEqual(to: domain) ? nil : name
        }
    }

    private static func keptKey(_ name: String) -> String { "removed-domain." + name }

    private static func deviceName() -> String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "iphone" : name
    }

    private static func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: Tsync.configFile),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }
}
