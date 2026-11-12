import Foundation
import PushKit

/// ios.md §5.3: the extension registers for file provider pushes and gives
/// each booted domain's server the token, once per process. The system turns a
/// push into a working-set signal itself.
final class Pushes: NSObject, PKPushRegistryDelegate {
    private static let shared = Pushes()
    private let lock = NSLock()
    private var registry: PKPushRegistry?
    private var token: String?
    private var domains: Set<String> = []
    private var asked: Set<String> = []

    static func booted(_ domain: String) { shared.add(domain) }

    private func add(_ domain: String) {
        lock.lock()
        domains.insert(domain)
        if registry == nil {
            let registry = PKPushRegistry(queue: DispatchQueue(label: "pushes"))
            registry.delegate = self
            registry.desiredPushTypes = [.fileProvider]
            self.registry = registry
        }
        let token = token
        lock.unlock()
        if let token = token { send(domain, token) }
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        let hex = credentials.token.map { String(format: "%02x", $0) }.joined()
        lock.lock()
        token = hex
        let domains = domains
        lock.unlock()
        for domain in domains { send(domain, hex) }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        lock.lock()
        token = nil
        lock.unlock()
    }

    func pushRegistry(
        _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType, completion: @escaping () -> Void
    ) {
        Footprint.append("push for \(payload.dictionaryPayload["domain"] ?? "?")")
        completion()
    }

    private func send(_ domain: String, _ token: String) {
        lock.lock()
        let fresh = asked.insert(domain + " " + token).inserted
        lock.unlock()
        guard fresh else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                let reply = try Owner(domain: domain).call(
                    "push_register",
                    [
                        "token": token, "environment": Pushes.environment,
                        "fileProviderDomain": domainIdentifier(domain),
                    ])
                Footprint.append("push_register \(domain): pushes \(reply["pushes"] as? Bool ?? false)")
            } catch {
                Footprint.append("push_register \(domain) failed: \(error)")
            }
        }
    }

    /// A build signed for development carries a profile naming that APNs
    /// environment; an App Store build carries none.
    static let environment: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url)
        else { return "production" }
        let profile = String(decoding: data, as: UTF8.self)
        guard let key = profile.range(of: "<key>aps-environment</key>") else { return "production" }
        return profile[key.upperBound...].prefix(80).contains("<string>development</string>")
            ? "development" : "production"
    }()
}
